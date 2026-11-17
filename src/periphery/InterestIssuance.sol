// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Interest issuance (LS_06 #177): the Stability Pool's depositors are paid the protocol's interest in OCT.
*
* The pool's lineage pays an emissions token to depositors through its issuance slot (Liquity's CommunityIssuance:
* the pool asks `issueLQTY()` how much arrived since it last asked, books it to depositors pro rata through its
* G sum, and pays it out with `sendLQTY()` when a depositor withdraws or claims). This contract fills that slot
* with OCT: whatever the interest splitter sends here is issued to the pool's depositors at the pool's next
* operation. Nothing is issued while the pool is empty, so no OCT is ever stranded in the pool's accounting;
* it waits here for the first depositor. No owner, no parameter, no schedule: the pool is paid what the
* borrowers pay.
*/
interface IIssuanceERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface IIssuancePool { function getTotalLUSDDeposits() external view returns (uint); }

contract InterestIssuance {
    IIssuanceERC20 public immutable octToken;
    address public immutable stabilityPool;

    uint public accounted;   // OCT handed to the pool's accounting so far
    uint public paidOut;     // OCT paid to depositors so far

    event Issued(uint amount);
    event Paid(address indexed depositor, uint amount);

    constructor(address _octToken, address _stabilityPool) {
        require(_octToken != address(0) && _stabilityPool != address(0), "InterestIssuance: zero address");
        octToken = IIssuanceERC20(_octToken);
        stabilityPool = _stabilityPool;
    }

    /// OCT received and not yet issued to the pool
    function pending() public view returns (uint) {
        return octToken.balanceOf(address(this)) + paidOut - accounted;
    }

    /// The pool asks on every deposit, withdrawal and liquidation; the answer is everything that arrived since
    /// the last answer, or nothing while the pool is empty (it has nobody to book it to).
    function issueLQTY() external returns (uint amount) {
        require(msg.sender == stabilityPool, "InterestIssuance: caller is not the Stability Pool");
        if (IIssuancePool(stabilityPool).getTotalLUSDDeposits() == 0) return 0;
        amount = pending();
        if (amount == 0) return 0;
        accounted += amount;
        emit Issued(amount);
    }

    /// The pool pays a depositor his booked OCT
    function sendLQTY(address _account, uint _amount) external {
        require(msg.sender == stabilityPool, "InterestIssuance: caller is not the Stability Pool");
        if (_amount == 0) return;
        paidOut += _amount;
        require(octToken.transfer(_account, _amount), "InterestIssuance: transfer failed");
        emit Paid(_account, _amount);
    }

    /// The lineage's setter; everything here is fixed at deployment.
    function setAddresses(address, address) external pure {}
}
