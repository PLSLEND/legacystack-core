// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Testnet stand-in for USDe (18 decimals) with an open faucet, so the OCT/USDe pool can be traded against.
/// Testnet only; on mainnet the real Ethena USDe is used.
contract MockUSDe {
    string public name = "USDe (testnet)";
    string public symbol = "USDe";
    uint8 public decimals = 18;
    uint public totalSupply;
    uint public constant FAUCET_CAP = 100_000 ether;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    function mint(address to, uint amount) external {
        require(amount <= FAUCET_CAP, "faucet: at most 100,000 per call");
        balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint amount) external returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint amount) external returns (bool) { return _move(msg.sender, to, amount); }
    function transferFrom(address from, address to, uint amount) external returns (bool) {
        uint a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint).max) allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }
    function _move(address from, address to, uint amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); return true;
    }
}
