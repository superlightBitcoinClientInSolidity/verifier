import sys
import bitcoin
from bitcoin.core import (
    CBlockHeader,
    CheckProofOfWork,
    CheckBlockHeader,
    CheckProofOfWorkError,
    _SelectCoreParams,
    uint256_from_compact,
    Hash,
    uint256_from_str,
)

_SelectCoreParams("regtest")
from bitcoin.core import coreparams
from tqdm import tqdm
import pickle

GENESIS = b"\xf3\x0cF\xbe\xc5B\xa3t9\x95.\x0f\xfe\x0ea\r\xbb\xcd\xad\x97\xee\xd9\xba\x94U\xdc\x90\x05\xcbW\xfcR"

###
# Block header object
###
class CBlockHeaderPopow(CBlockHeader):
    __slots__ = ["hashInterlink"]

    def __init__(
        self,
        nVersion=2,
        hashPrevBlock=b"\x00" * 32,
        hashMerkleRoot=b"\x00" * 32,
        nTime=0,
        nBits=0,
        nNonce=0,
        hashInterlink=b"\x00" * 32,
    ):
        super(CBlockHeaderPopow, self).__init__(
            nVersion, hashPrevBlock, hashMerkleRoot, nTime, nBits, nNonce
        )
        object.__setattr__(self, "hashInterlink", hashInterlink)

    @classmethod
    def stream_deserialize(cls, f):
        hashInterlink = f.read(32)
        self = super(CBlockHeaderPopow, cls).stream_deserialize(f)
        object.__setattr__(self, "hashInterlink", hashInterlink)
        return self

    def stream_serialize(self, f):
        f.write(self.hashInterlink)
        super(CBlockHeaderPopow, self).stream_serialize(f)

    def compute_level(self):
        target = bits_to_target(self.nBits)
        hash = uint256_from_str(self.GetHash())
        return (int(target / hash)).bit_length() - 1


def bits_to_target(bits):
    # bits to target
    bitsN = (bits >> 24) & 0xFF
    # print('bitsN: %s' % bitsN)
    # assert bitsN >= 0x03 and bitsN <= 0x1d, "First part of bits should be in [0x03, 0x1d]"
    assert (
        bitsN >= 0x03 and bitsN <= 0x20
    ), "First part of bits should be in [0x03, 0x20] (regtest)"
    bitsBase = bits & 0xFFFFFF
    # print('bitsBase: %s' % hex(bitsBase))
    assert (
        bitsBase >= 0x8000 and bitsBase <= 0x7FFFFF
    ), "Second part of bits should be in [0x8000, 0x7fffff]"
    target = bitsBase << (8 * (bitsN - 3))
    return target


###
# Builds a merkle tree over an Interlink vector
###
def hash_interlink(vInterlink=[]):
    if len(vInterlink) >= 2:
        hashL = hash_interlink(vInterlink[: int(len(vInterlink) / 2)])
        hashR = hash_interlink(vInterlink[int(len(vInterlink) / 2) :])
        return Hash(hashL + hashR)
    elif len(vInterlink) == 1:
        return vInterlink[0]
    else:
        return b"\x00" * 32


def prove_interlink(vInterlink, mu):
    # Merkle tree proof
    assert 0 <= mu < len(vInterlink)
    if len(vInterlink) >= 2:
        midway = int(len(vInterlink) / 2)
        if mu < midway:
            hashR = hash_interlink(vInterlink[midway:])
            return [(0, hashR)] + prove_interlink(vInterlink[:midway], mu)
        else:
            hashL = hash_interlink(vInterlink[:midway])
            return [(1, hashL)] + prove_interlink(vInterlink[midway:], mu - midway)
    elif len(vInterlink) == 1:
        return []
    else:
        raise Exception


def verify_interlink(h, hashInterlink, proof):
    """
    returns: mu
    """
    mu = 0
    for i, (bit, sibling) in enumerate(proof[::-1]):
        mu += bit << i
        assert len(sibling) == 32
        if bit:
            h = Hash(sibling + h)
        else:
            h = Hash(h + sibling)
    assert h == hashInterlink, "root hash did not match"
    return mu


###
# Cons lists (to enable pointer sharing when building the header chain)
###
def list_append(xs, x):
    if xs == ():
        return (x, ())
    else:
        return (xs[0], list_append(xs[1], x))


def list_flatten(xs):
    r = []
    while xs != ():
        x, xs = xs
        r.append(x)
    return r


def list_replace_first_n(xs, x, n):
    """
    returns a list the same as `xs`, except the first
    `n` elements are `x`

    > list_replace_first_n([], 'a', 3):
    ('a', ('a', ('a', ())))
    """
    if n <= 0:
        return xs
    else:
        if xs == ():
            return (x, list_replace_first_n((), x, n - 1))
        else:
            return (x, list_replace_first_n(xs[1], x, n - 1))


###
# Saving and loading
###
def save_blockchain(f, header, headerMap, mapInterlink):
    headerMap = dict((k, v.serialize()) for (k, v) in headerMap.items())
    pickle_out = open(f, "wb")
    pickle.dump((header.serialize(), headerMap, mapInterlink), pickle_out)
    pickle_out.close()


def load_blockchain(f):
    pickle_in = open(f, "rb")
    header, headerMap, mapInterlink = pickle.load(pickle_in)
    headerMap = dict(
        (k, CBlockHeaderPopow.deserialize(v)) for (k, v) in headerMap.items()
    )
    header = CBlockHeaderPopow.deserialize(header)
    return header, headerMap, mapInterlink


"""
Useful commands to run:

  header, headerMap, mapInterlink = load_blockchain(open('450k.pkl'))

To build again:
  header, headerMap, mapInterlink = create_blockchain()

Then to save:
  with open('450k.pkl','w') as f: save_blockchain(f, (header, headerMap, mapInterlink))

"""


###
# Simulate mining
###


def mine_block(
    hashPrevBlock=b"\xbb" * 32,
    nBits=0x207FFFFF,
    vInterlink=[],
    hashMerkleRoot=b"\xaa" * 32,
):
    for nNonce in range(2 ** 31):
        header = CBlockHeaderPopow(
            hashPrevBlock=hashPrevBlock,
            hashMerkleRoot=hashMerkleRoot,
            nBits=nBits,
            nNonce=nNonce,
            hashInterlink=hash_interlink(vInterlink),
        )
        try:
            CheckProofOfWork(header.GetHash(), header.nBits)
            break
        except CheckProofOfWorkError:
            continue
    return header


# Unfolds the tuple and puts genesis inside
def add_genesis_to_interlink(interlink, genesis):
    if interlink == (genesis, ()):
        return (genesis, ())
    if interlink == ():
        return (genesis, ())
    f, s = interlink
    return (f, add_genesis_to_interlink(s, genesis))


def create_blockchain(
    genesis=None,
    blocks=450000,
    headerMap=None,
    mapInterlink=None,
    hashMerkleRoot=b"\x00" * 32,
):
    # This way of handling the mapInterlink only requires O(N) space
    # Rather than O(N log N) when done naively
    if headerMap is None:
        headerMap = {}
    # if heightMap is None: heightMap = {}
    if mapInterlink is None:
        mapInterlink = {}

    if genesis is None:
        genesis = mine_block()
        listInterlink = ()
    else:
        listInterlink = mapInterlink[genesis.GetHash()]

    header = None
    for i in tqdm(range(blocks), desc="Creating blockchain"):
        listInterlink = add_genesis_to_interlink(listInterlink, GENESIS)
        vInterlink = list_flatten(listInterlink)
        if header is None:
            header = genesis
        else:
            header = mine_block(
                header.GetHash(),
                header.nBits,
                vInterlink,
                hashMerkleRoot=hashMerkleRoot,
            )

        headerMap[header.GetHash()] = header  # Persist the header
        mapInterlink[header.GetHash()] = listInterlink
        # heightMap[header.GetHash()] = i

        mu = header.compute_level()
        # Update interlink vector, extending if necessary
        for u in range(mu + 1):
            listInterlink = list_replace_first_n(
                listInterlink, header.GetHash(), mu + 1
            )

        # print header.GetHash()[::-1].encode('hex')
        # print header.compute_level()
        # if i % 10000 == 0:
        #     print('*'*(header.compute_level()+1))
        # print [h[::-1][:3].encode('hex') for h in vInterlink]

    return header, headerMap, mapInterlink


###
# Create NiPoPoW proofs
###

"""
To run:
  proof = make_proof(header, headerMap, mapInterlink)
"""


def make_proof(header, headerMap, mapInterlink, m=15, k=15):
    # Try making proofs at the tallest levels down
    vInterlink = list_flatten(mapInterlink[header.GetHash()])

    # Start at the base level
    mu = 0
    from collections import defaultdict

    num_at_level = defaultdict(lambda: 0)
    proof = []
    mp = []
    while True:
        # TODO: go for the first k blocks
        proof.append((header.serialize(), mp))
        _mu = header.compute_level()
        for i in range(mu, _mu + 1):
            num_at_level[i] += 1

        # Advance current-level if at least m samples at the next level
        while num_at_level[mu + 1] >= m:
            mu += 1

        # Nothing else at current level
        # The last level is the genesis hash
        if mu >= len(vInterlink) - 1:
            break

        # Skip to the next block at current level
        mp = prove_interlink(vInterlink, mu)
        header = headerMap[vInterlink[mu]]

        verify_interlink(header.GetHash(), hash_interlink(vInterlink), mp)

        vInterlink = list_flatten(mapInterlink[header.GetHash()])

    # Iterate the rest of the proof at the maximum level of each block until genesis
    while header.GetHash() != GENESIS:
        genesis_level = len(list_flatten(mapInterlink[header.GetHash()])) - 1
        mp = prove_interlink(vInterlink, genesis_level)
        header = headerMap[vInterlink[-1]]
        verify_interlink(header.GetHash(), hash_interlink(vInterlink), mp)
        vInterlink = list_flatten(mapInterlink[header.GetHash()])
        proof.append((header.serialize(), mp))

    for hs_mp in proof:
        hs, mp = hs_mp
        # print(hs)
        header = CBlockHeaderPopow.deserialize(hs)
        h = header.GetHash()
        # print('*'*(header.compute_level()+1))
        # print(h[::-1][:3])
        vInterlink = list_flatten(mapInterlink[h])
        # print([_h[::-1][:3] for _h in vInterlink])
        # print([(b,h[::-1][:3]) for (b,h) in mp])
    return proof


"""
call with:
   verify_proof(Hash(proof[0][0]), proof)
"""


def verify_proof(h, proof):
    proof = iter(proof)
    hs, _ = next(proof)
    header = CBlockHeaderPopow.deserialize(hs)
    assert header.GetHash() == h
    for hs, merkle_proof in proof:
        hashInterlink = header.hashInterlink
        header = CBlockHeaderPopow.deserialize(hs)
        # Check hash matches
        verify_interlink(header.GetHash(), hashInterlink, merkle_proof)


###
# Graphing
###


def draw_fullgraph(header, headerMap):
    global scores
    scores = []
    while True:
        scores.append(header.compute_level())
        header = headerMap[header.hashPrevBlock]
        if header.hashPrevBlock == b"\xbb" * 32:
            break


def create_fork(header, headerMap, mapInterlink, fork=50000, blocks=1000):
    # Walk backward `fork` blocks
    for i in range(fork):
        header = headerMap[header.hashPrevBlock]
    header, headerMap, mapInterlink = create_blockchain(
        header, blocks, headerMap, mapInterlink, hashMerkleRoot=b"\xcc" * 32
    )

    return header, headerMap, mapInterlink
