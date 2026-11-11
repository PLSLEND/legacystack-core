// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Reserve rewards (LS_06 #160, #161): STACK emissions for reserve depositors, paid for the time their wstETH
* served the Redemption Reserve. The core only counts points (wstETH-seconds); this contract pays a fixed
* amount of STACK per point out of whatever it holds, first come first served, and nothing when it is empty.
* Anyone may fund it. No owner: the rate is fixed at deployment; a new schedule is a new contract.
*/
interface IRewardsERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface IRewardsBuffer { function pointsOf(address) external view returns (uint); function checkpoint(address) external; }

contract ReserveRewards {
    IRewardsERC20 public immutable stack;
    IRewardsBuffer public immutable reserve;
    uint public immutable ratePerPoint;             // STACK (18 dec) per wstETH-second, scaled by 1e18

    mapping(address => uint) public paidPoints;     // points already paid for
    uint public totalPaid;

    event Claimed(address indexed depositor, uint points, uint stackOut);

    constructor(address _stack, address _reserve, uint _ratePerPoint) {
        require(_stack != address(0) && _reserve != address(0), "ReserveRewards: zero address");
        require(_ratePerPoint > 0, "ReserveRewards: zero rate");
        stack = IRewardsERC20(_stack);
        reserve = IRewardsBuffer(_reserve);
        ratePerPoint = _ratePerPoint;
    }

    /// STACK a depositor could claim now: unpaid points at the rate, capped by what this contract holds
    function claimable(address _depositor) public view returns (uint) {
        uint earned = (reserve.pointsOf(_depositor) - paidPoints[_depositor]) * ratePerPoint / 1e18;
        uint held = stack.balanceOf(address(this));
        return earned < held ? earned : held;
    }

    function claim() external returns (uint stackOut) {
        reserve.checkpoint(msg.sender);
        uint points = reserve.pointsOf(msg.sender);
        uint unpaid = points - paidPoints[msg.sender];
        stackOut = unpaid * ratePerPoint / 1e18;
        uint held = stack.balanceOf(address(this));
        if (stackOut > held) {
            // pay what is here and keep the unpaid remainder as points for later
            stackOut = held;
            unpaid = held * 1e18 / ratePerPoint;
        }
        require(stackOut > 0, "ReserveRewards: nothing to claim");
        paidPoints[msg.sender] += unpaid;
        totalPaid += stackOut;
        require(stack.transfer(msg.sender, stackOut), "ReserveRewards: transfer failed");
        emit Claimed(msg.sender, unpaid, stackOut);
    }
}
