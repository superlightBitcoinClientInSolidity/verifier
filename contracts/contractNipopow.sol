pragma solidity ^0.6.2;


//import "strings.sol";

contract Crosschain {
    constructor(bytes32 genesis, uint _m, uint _k) public {
        genesisBlockHash = genesis;
        m = _m;
        k = _k;
    }

    // The genesis block hash
    bytes32 genesisBlockHash;
    // Collateral to pay.
    uint256 constant z = 0.1 ether;

    mapping(uint256 => uint256) levelCounter;

    struct Event {
        address payable author;
        uint256 expire;
        bytes32 proofHash;
        bytes32 hashedProofHash;
        bytes32 siblingsHash;
    }

    // the block header hash.
    mapping(bytes32 => Event) events;
    mapping(bytes32 => bool) finalizedEvents;

    // Security parameters.
    uint256 m;
    uint256 k;

    //TOOO: Move this to another file
    function memcpy(uint256 dest, uint256 src, uint256 len) private pure {
        // Copy word-length chunks while possible
        for (; len >= 32; len -= 32) {
            assembly {
                mstore(dest, mload(src))
            }
            dest += 32;
            src += 32;
        }
        // Copy remaining bytes.
        uint256 mask = 256**(32 - len) - 1;
        assembly {
            let srcpart := and(mload(src), not(mask))
            let destpart := and(mload(dest), mask)
            mstore(dest, or(destpart, srcpart))
        }
    }

    // TODO: move this to another file
    // Hash the header using double SHA256
    function hashHeader(bytes32[4] memory header)
        internal
        pure
        returns (bytes32)
    {
        // Compute the hash of 112-byte header.
        string memory s = new string(112);
        uint256 sptr;
        uint256 hptr;
        assembly {
            sptr := add(s, 32)
        }
        assembly {
            hptr := add(header, 0)
        }
        memcpy(sptr, hptr, 112);
        return sha256(abi.encodePacked(sha256(abi.encodePacked(s))));
    }

    // TODO: Implement the O(log(maxLevel)) algorithm.
    function getLevel(bytes32 hashedHeader) internal pure returns (uint256) {
        uint256 hash = uint256(hashedHeader);

        for (uint256 i = 0; i <= 255; i++) {
            // Change endianess.
            uint256 pow = (i / 8) * 8 + 8 - (i % 8) - 1;
            uint256 mask = 2**pow;
            if ((hash & mask) != 0) {
                return uint8(i) - 1;
            }
        }
        return 0;
    }

    function argAtLevel(bytes32[] memory proof, uint256 level)
        internal
        pure
        returns (uint256)
    {
        uint256 blocksOfLevel = 0;
        for (uint256 i = 0; i < proof.length; i++) {
            if (getLevel(proof[i]) >= level) {
                blocksOfLevel++;
            }
        }
        uint256 score = uint256(blocksOfLevel * 2**level);
        return score;
    }

    // TODO: lca can be very close to the tip of submited proof so that
    // score(existing[lca:]) < score(contesting[lca:]) because
    // |existing[:lca]| < m
    function bestArg(bytes32[] memory proof, uint256 lca)
        internal
        returns (uint256)
    {
        uint256 maxLevel = 0;
        uint256 maxScore = 0;
        uint256 curLevel = 0;

        // Count the frequency of the levels.
        for (uint256 i = 0; i < lca; i++) {
            curLevel = getLevel(proof[i]);

            // Superblocks of level m are also superblocks of level m - 1.
            for (uint256 j = 0; j <= curLevel; j++) {
                levelCounter[j]++;
            }

            if (maxLevel < curLevel) {
                maxLevel = curLevel;
            }
        }

        for (uint256 i = 0; i <= maxLevel; i++) {
            uint256 curScore = uint256(levelCounter[i] * 2**i);
            if (levelCounter[i] >= m && curScore > maxScore) {
                maxScore = levelCounter[i] * 2**i;
            }
            // clear the map.
            levelCounter[i] = 0;
        }

        return maxScore;
    }

    function verifyMerkle(
        bytes32 roothash,
        bytes32 leaf,
        uint8 mu,
        bytes32[] memory siblings
    ) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < siblings.length; i++) {
            uint8 bit = mu & 0x1;
            if (bit == 1) {
                h = sha256(
                    abi.encodePacked(
                        sha256(
                            abi.encodePacked(
                                siblings[siblings.length - i - 1],
                                h
                            )
                        )
                    )
                );
            } else {
                h = sha256(
                    abi.encodePacked(
                        sha256(
                            abi.encodePacked(
                                h,
                                siblings[siblings.length - i - 1]
                            )
                        )
                    )
                );
            }
            mu >>= 1;
        }
        return h == roothash;
    }

    // shift bits to the most segnificant byte (256-8 = 248)
    // and cast it to a 8-bit uint
    function b32ToUint8(bytes32 b) private pure returns (uint8) {
        return uint8(bytes1(b << 248));
    }

    function findSiblingsOffset(
        bytes32[4][] memory headers,
        uint256 proofIndex
    ) internal pure returns (uint256) {
        uint256 ptr;

        for (uint256 i = 1; i < proofIndex; i++) {
            // hold the 3rd and 4th least significant bytes
            uint8 branchLength = b32ToUint8(
                (headers[i][3] >> 8) & bytes32(uint256(0xff))
            );
            require(branchLength <= 5, "Branch length too big");
            ptr += branchLength;
        }

        return ptr;
    }

    function validateSingleInterlink(
        bytes32[4][] memory headers,
        bytes32[] memory siblings,
        uint256 validateIndex
    ) internal pure returns (bool) {
        uint256 siblingsOffset = findSiblingsOffset(
            headers,
            validateIndex
        );

        uint8 branchLength = b32ToUint8(
            (headers[validateIndex][3] >> 8) & bytes32(uint256(0xff))
        );
        uint8 merkleIndex = b32ToUint8(
            (headers[validateIndex][3] >> 0) & bytes32(uint256(0xff))
        );
        bytes32[] memory reversedSiblings = new bytes32[](branchLength);
        for (uint8 j = 0; j < branchLength; j++)
            reversedSiblings[j] = siblings[siblingsOffset + j];

        return
            verifyMerkle(
                headers[validateIndex - 1][0],
                hashHeader(headers[validateIndex]),
                merkleIndex,
                reversedSiblings
            );
    }

    function validateInterlinks(
        bytes32[4][] memory headers,
        bytes32[] memory hashedHeaders,
        bytes32[] memory siblings
    ) internal pure returns (bool) {
        uint256 ptr = 0; // Index of the current sibling
        for (uint256 i = 1; i < headers.length; i++) {
            // hold the 3rd and 4th least significant bytes
            uint8 branchLength = b32ToUint8(
                (headers[i][3] >> 8) & bytes32(uint256(0xff))
            );
            uint8 merkleIndex = b32ToUint8(
                (headers[i][3] >> 0) & bytes32(uint256(0xff))
            );

            require(branchLength <= 5, "Branch length too big");
            require(merkleIndex <= 32, "Merkle index too big");

            // Copy siblings.
            bytes32[] memory reversedSiblings = new bytes32[](branchLength);
            for (uint8 j = 0; j < branchLength; j++)
                reversedSiblings[j] = siblings[ptr + j];
            ptr += branchLength;


            // Verify the merkle tree proof
            if (
                !verifyMerkle(
                    headers[i - 1][0],
                    hashedHeaders[i],
                    merkleIndex,
                    reversedSiblings
                )
            ) {
                return false;
            }
        }
        return true;
    }

    function submitEventProof(
        bytes32[4][] memory headers,
        bytes32[] memory siblings,
        uint256 blockOfInterestIndex
    ) public payable returns (bool) {
        require(msg.value >= z, "insufficient collateral");
        require(
            headers.length > blockOfInterestIndex && blockOfInterestIndex >= 0,
            "Block of interest index is out of range"
        );

        bytes32 hashedBlock = hashHeader(headers[blockOfInterestIndex]);
        require(
            events[hashedBlock].expire == 0,
            "The submission period has expired"
        );
        require(
            events[hashedBlock].proofHash == 0,
            "A proof with this evens exists"
        );
        require(
            hashHeader(headers[headers.length - 1]) == genesisBlockHash,
            "Proof does not include the genesis block"
        );

        bytes32[] memory hashedHeaders = new bytes32[](headers.length);
        for (uint256 i = 0; i < headers.length; i++) {
            hashedHeaders[i] = hashHeader(headers[i]);
        }

        events[hashedBlock].proofHash = sha256(abi.encodePacked(headers));
        events[hashedBlock].hashedProofHash = sha256(
            abi.encodePacked(hashedHeaders)
        );
        events[hashedBlock].siblingsHash = sha256(abi.encodePacked(siblings));
        events[hashedBlock].expire = block.number + k;
        events[hashedBlock].author = msg.sender;

        return true;
    }

    function finalizeEvent(bytes32[4] memory blockOfInterest)
        public
        returns (bool)
    {
        bytes32 hashedBlock = hashHeader(blockOfInterest);

        if (
            events[hashedBlock].expire == 0 ||
            block.number < events[hashedBlock].expire
        ) {
            return false;
        }
        finalizedEvents[hashedBlock] = true;
        events[hashedBlock].expire = 0;
        events[hashedBlock].author.transfer(z);

        return true;
    }

    // If this will be expensive, check memory mapping
    // Check if existing[0:lca] is disjoint from contesting[:-1]
    // existing[0] is the tip of existing, existing[-1] is the genesis
    // contesting[0] is the tip of contesting, contestin[-1] is the lca
    function disjointProofs(
        bytes32[] memory existing,
        bytes32[] memory contesting,
        uint256 lca
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < lca; i++) {
            for (uint256 j = 0; j < contesting.length - 1; j++) {
                if (existing[i] == contesting[j]) {
                    return false;
                }
            }
        }
        return true;
    }

    function disputeExistingProof(
        bytes32[4][] memory existingHeaders,
        bytes32[] memory siblings,
        uint256 blockOfInterestIndex,
        uint256 disputeIndex
    ) public returns (bool) {
        bytes32 blockOfInterestHash = hashHeader(
            existingHeaders[blockOfInterestIndex]
        );

        require(
            events[blockOfInterestHash].expire > block.number,
            "Contesting period has expired"
        );
        require(
            events[blockOfInterestHash].proofHash ==
                sha256(abi.encodePacked(existingHeaders)),
            "Wrong existing proof"
        );
        require(
            events[blockOfInterestHash].siblingsHash ==
                sha256(abi.encodePacked(siblings)),
            "Wrong siblings"
        );
        require(
            1 <= disputeIndex && disputeIndex < existingHeaders.length,
            "Dispute index out of range"
        );
        require(
            !validateSingleInterlink(existingHeaders, siblings, disputeIndex),
            "Existing proof is valid at this index"
        );

        // If you reached this point, contesting was successful
        events[blockOfInterestHash].expire = 0;
        msg.sender.transfer(z);
        return true;
    }

    function submitContestingProof(
        bytes32[] memory existingHeadersHashed,
        uint256 lca,
        bytes32[4][] memory contestingHeaders,
        bytes32[] memory contestingSiblings,
        uint256 bestLevel,
        uint256 blockOfInterestIndex
    ) public returns (bool) {
        require(
            existingHeadersHashed.length > blockOfInterestIndex &&
                blockOfInterestIndex >= 0,
            "Block of interest index is out of range"
        );

        require(
            existingHeadersHashed.length >= m, "Security parameter m violated"
        );

            bytes32 blockOfInterestHash
         = existingHeadersHashed[blockOfInterestIndex];

        require(
            events[blockOfInterestHash].expire > block.number,
            "Contesting period has expired"
        );

        require(existingHeadersHashed.length > lca, "Lca out of range");

        require(
            lca > blockOfInterestIndex,
            "Block of interest exists in sub-chain"
        );

        require(
            events[blockOfInterestHash].hashedProofHash ==
                sha256(abi.encodePacked(existingHeadersHashed)),
            "Wrong existing proof"
        );

        bytes32[] memory contestingHeadersHashed = new bytes32[](
            contestingHeaders.length
        );
        for (uint256 i = 0; i < contestingHeaders.length; i++) {
            contestingHeadersHashed[i] = hashHeader(contestingHeaders[i]);
        }

        require(
            validateInterlinks(
                contestingHeaders,
                contestingHeadersHashed,
                contestingSiblings
            ),
            "Merkle verification failed"
        );

        require(
            existingHeadersHashed[lca] ==
                contestingHeadersHashed[contestingHeaders.length - 1],
            "Wrong lca"
        );

        require(
            disjointProofs(existingHeadersHashed, contestingHeadersHashed, lca),
            "Contesting proof[1:] is not different from existing[lca+1:]"
        );

        require(
            bestArg(existingHeadersHashed, lca) <
                argAtLevel(contestingHeadersHashed, bestLevel),
            "Existing proof has greater score"
        );

        // If you reached this point, contesting was successful
        events[blockOfInterestHash].expire = 0;
        msg.sender.transfer(z);
        return true;
    }

    function eventExists(bytes32[4] memory blockHeader)
        public
        view
        returns (bool)
    {
        bytes32 hashedBlock = hashHeader(blockHeader);
        return finalizedEvents[hashedBlock];
    }
}
