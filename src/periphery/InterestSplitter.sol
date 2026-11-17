// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Interest splitter (LS_06 #177): where the minted interest goes.
*
* TroveManager mints the accrued interest here. Anyone may call split(): half goes to the Stability Pool's
* depositors (through the interest issuance contract, paid in OCT), half to the liquidity desk, where it is paid
* to the dollars resting under par in the OCT/USDe pool. A half whose venue is empty (no deposits in the pool,
* no bids on the desk, or no desk at all on this chain) goes to the Redemption Buffer's inventory instead: if
* nobody is there to be paid, the buffer keeps it. No owner, no parameter after deployment; the shares are
* constants.
*/
interface ISplitERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface ISplitPool { function getTotalLUSDDeposits() external view returns (uint); }
interface ISplitDesk { function totalBidLiquidity() external view returns (uint128); function notifyReward(uint) external; }

contract InterestSplitter {
    ISplitERC20 public immutable octToken;
    ISplitPool public immutable stabilityPool;
    address public immutable issuance;        // the Stability Pool's interest issuance contract
    ISplitDesk public immutable desk;         // the liquidity desk (bids paid); zero on a chain without one
    address public immutable buffer;          // the Redemption Buffer (inventory)
    uint public constant POOL_BPS = 5000;     // the Stability Pool's half; the desk gets the rest

    uint public totalToPool; uint public totalToDesk; uint public totalToBuffer;

    event Split(uint toPool, uint toDesk, uint toBuffer);

    constructor(address _octToken, address _stabilityPool, address _issuance, address _desk, address _buffer) {
        require(_octToken != address(0) && _stabilityPool != address(0) && _issuance != address(0) && _buffer != address(0), "InterestSplitter: zero address");
        octToken = ISplitERC20(_octToken);
        stabilityPool = ISplitPool(_stabilityPool);
        issuance = _issuance;
        desk = ISplitDesk(_desk);
        buffer = _buffer;
    }

    /// Interest minted here and not yet routed
    function pending() public view returns (uint) { return octToken.balanceOf(address(this)); }

    function split() external returns (uint toPool, uint toDesk, uint toBuffer) {
        uint amount = pending();
        if (amount == 0) return (0, 0, 0);
        toPool = amount * POOL_BPS / 10000;
        toDesk = amount - toPool;
        if (stabilityPool.getTotalLUSDDeposits() == 0) { toBuffer += toPool; toPool = 0; }
        if (address(desk) == address(0) || desk.totalBidLiquidity() == 0) { toBuffer += toDesk; toDesk = 0; }
        if (toPool > 0) { require(octToken.transfer(issuance, toPool), "InterestSplitter: transfer failed"); totalToPool += toPool; }
        if (toDesk > 0) { require(octToken.transfer(address(desk), toDesk), "InterestSplitter: transfer failed"); desk.notifyReward(toDesk); totalToDesk += toDesk; }
        if (toBuffer > 0) { require(octToken.transfer(buffer, toBuffer), "InterestSplitter: transfer failed"); totalToBuffer += toBuffer; }
        emit Split(toPool, toDesk, toBuffer);
    }
}
