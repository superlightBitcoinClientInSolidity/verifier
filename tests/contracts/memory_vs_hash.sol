pragma solidity ^0.6.4;

contract CompareHashMemory{

    bytes32[] best;

    function mem(bytes32[] memory array)
    public
    pure
    returns (bool)
    {
        bytes32[] memory a = new bytes32[](10000);
        return array[0] == array[0];
    }

    function hash(bytes32[] memory array, uint256 t)
    public
    pure
    returns (bytes32)
    {
        bytes32 h = array[0];
        for(uint256 i=0; i<t; i++) {
            h = sha256(abi.encodePacked(h));
        }
        return h;
    }
}
