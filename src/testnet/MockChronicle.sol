// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Testnet stand-in for a Chronicle ETH/USD oracle: a value with 18 decimals and the time it was set.
/// The deployer (a throwaway testnet key) may move it to rehearse disagreement, staleness and death;
/// on Ethereum the real Chronicle oracle is used. Testnet only.
contract MockChronicle {
    address public immutable setter;
    uint public value;
    uint public age;
    bool public dead;
    constructor(uint _value) { setter = msg.sender; value = _value; age = block.timestamp; }
    function set(uint _value, uint _age) external { require(msg.sender == setter, "chronicle: not the setter"); value = _value; age = _age; }
    function setDead(bool _dead) external { require(msg.sender == setter, "chronicle: not the setter"); dead = _dead; }
    function readWithAge() external view returns (uint, uint) { require(!dead, "chronicle: no value"); return (value, age); }
}
