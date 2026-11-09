// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Testnet wstETH: ERC-20 with an open faucet (capped per call), a stETH-per-token rate that only the
/// deployer can move, and the real contract's behaviour of minting wstETH for ETH sent to it (Lido's wstETH
/// stakes the ETH and wraps the shares; here the test ETH is parked and the deployer can recycle it).
/// Testnet only; on mainnet the real Lido wstETH is used.
contract MockWstETH {
    string public name = "Wrapped liquid staked Ether 2.0 (testnet)";
    string public symbol = "wstETH";
    uint8 public decimals = 18;
    uint public totalSupply;
    uint public stEthPerToken = 1.2e18;
    uint public constant FAUCET_CAP = 10_000 ether;
    address public immutable rateSetter;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    constructor() { rateSetter = msg.sender; }

    /// ETH in, wstETH out at the current rate: the same entry point as Lido's wstETH contract.
    receive() external payable {
        uint amount = msg.value * 1e18 / stEthPerToken;
        require(amount > 0, "wstETH: zero");
        balanceOf[msg.sender] += amount; totalSupply += amount; emit Transfer(address(0), msg.sender, amount);
    }
    /// Testnet housekeeping: the parked test ETH goes back to the deployer for reuse.
    function recycle() external { require(msg.sender == rateSetter, "rate: not the setter"); payable(rateSetter).transfer(address(this).balance); }

    function mint(address to, uint amount) external {
        require(amount <= FAUCET_CAP, "faucet: at most 10,000 per call");
        balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount);
    }
    function setStEthPerToken(uint r) external { require(msg.sender == rateSetter, "rate: not the setter"); stEthPerToken = r; }
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
