// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Surplus splitter (LS_06 #161): the reserve's surplus sink. Whatever wstETH the waterfall sends here is
* split in two by whoever calls split(): half to the burn auction, half to the protocol-owned-liquidity
* keeper. Periphery: no owner, no parameter, no rule beyond the halves. When a venue's day is over, the
* next DEPLOYMENT points its reserve at a new splitter; this one keeps splitting.
*/
interface ISplitERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface ISplitAuction { function notify() external; }

contract SurplusSplitter {
    ISplitERC20 public immutable collateralToken;
    address public immutable burnAuction;
    address public immutable polKeeper;

    event Split(uint toAuction, uint toPol);

    constructor(address _collateralToken, address _burnAuction, address _polKeeper) {
        require(_collateralToken != address(0) && _burnAuction != address(0) && _polKeeper != address(0), "SurplusSplitter: zero address");
        collateralToken = ISplitERC20(_collateralToken);
        burnAuction = _burnAuction;
        polKeeper = _polKeeper;
    }

    function pending() external view returns (uint) {
        return collateralToken.balanceOf(address(this));
    }

    function split() external returns (uint toAuction, uint toPol) {
        uint balance = collateralToken.balanceOf(address(this));
        require(balance > 0, "SurplusSplitter: nothing to split");
        toAuction = balance / 2;
        toPol = balance - toAuction;
        require(collateralToken.transfer(burnAuction, toAuction), "SurplusSplitter: transfer failed");
        require(collateralToken.transfer(polKeeper, toPol), "SurplusSplitter: transfer failed");
        ISplitAuction(burnAuction).notify();
        emit Split(toAuction, toPol);
    }
}
