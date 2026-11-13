// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Surplus splitter (LS_06 #161, #172): the reserve's surplus sink. Whatever wstETH the waterfall sends here is
* split by whoever calls split(): while the protocol-owned liquidity is below its target, all of it goes to
* the POL keeper (the pool's depth comes first); once the target is reached, half to the burn auction and half
* to the keeper. The caller is paid 0.1% of what is split, at most 0.02 wstETH, so the button is worth pressing.
* Periphery: no owner, no parameter. When a venue's day is over, the next DEPLOYMENT points its reserve at a new
* splitter; this one keeps splitting.
*/
interface ISplitERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface ISplitAuction { function notify() external; }
interface ISplitPol { function belowTarget() external view returns (bool); }

contract SurplusSplitter {
    ISplitERC20 public immutable collateralToken;
    address public immutable burnAuction;
    address public immutable polKeeper;
    uint public constant CALLER_BPS = 10;          // the caller's cut of what is split ...
    uint public constant CALLER_CAP = 0.02 ether;  // ... and never more than this

    event Split(uint toAuction, uint toPol, uint toCaller);

    constructor(address _collateralToken, address _burnAuction, address _polKeeper) {
        require(_collateralToken != address(0) && _burnAuction != address(0) && _polKeeper != address(0), "SurplusSplitter: zero address");
        collateralToken = ISplitERC20(_collateralToken);
        burnAuction = _burnAuction;
        polKeeper = _polKeeper;
    }

    function pending() external view returns (uint) {
        return collateralToken.balanceOf(address(this));
    }

    /// All to the keeper while the protocol's liquidity is below target; half and half once it is there.
    function polFirst() public view returns (bool) {
        if (polKeeper == burnAuction) return false;
        try ISplitPol(polKeeper).belowTarget() returns (bool below) { return below; } catch { return false; }
    }

    function split() external returns (uint toAuction, uint toPol) {
        uint balance = collateralToken.balanceOf(address(this));
        require(balance > 0, "SurplusSplitter: nothing to split");
        uint toCaller = balance * CALLER_BPS / 10000;
        if (toCaller > CALLER_CAP) toCaller = CALLER_CAP;
        balance -= toCaller;
        toAuction = polFirst() ? 0 : balance / 2;
        toPol = balance - toAuction;
        if (toCaller > 0) require(collateralToken.transfer(msg.sender, toCaller), "SurplusSplitter: transfer failed");
        if (toAuction > 0) require(collateralToken.transfer(burnAuction, toAuction), "SurplusSplitter: transfer failed");
        require(collateralToken.transfer(polKeeper, toPol), "SurplusSplitter: transfer failed");
        if (toAuction > 0) ISplitAuction(burnAuction).notify();
        emit Split(toAuction, toPol, toCaller);
    }
}
