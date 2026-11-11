// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IStackT { function mint(address, uint) external; function approve(address, uint) external returns (bool); function balanceOf(address) external view returns (uint); function totalSupply() external view returns (uint); function totalBurned() external view returns (uint); }
interface IAuction {
    function lot() external view returns (uint); function price() external view returns (uint); function cost() external view returns (uint);
    function startPrice() external view returns (uint); function empty() external view returns (bool);
    function notify() external; function buy(uint) external; function totalBurned() external view returns (uint);
}
interface ISplitter { function split() external returns (uint, uint); function pending() external view returns (uint); }
interface IRewards { function claimable(address) external view returns (uint); function claim() external returns (uint); function paidPoints(address) external view returns (uint); }
interface IPol { function work() external returns (uint); function octAtOrAbovePar() external view returns (bool); function positionCount() external view returns (uint); function totalCollToAuction() external view returns (uint); function totalOctDeposited() external view returns (uint); }

/// A stand-in for the Uniswap v3 pool and position manager: enough surface for the keeper's rule and failure path.
contract MockPool {
    address public token0; address public token1; uint24 public fee = 500; int24 public tickSpacing = 10;
    int24 public tick; bool public observeFails = true;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setTick(int24 t) external { tick = t; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) { return (0, tick, 0, 0, 0, 0, true); }
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory) { require(!observeFails, "OLD"); int56[] memory c = new int56[](2); uint160[] memory s = new uint160[](2); return (c, s); }
    function increaseObservationCardinalityNext(uint16) external {}
}
contract MockNPM {
    bool public fails; uint public minted; uint public lastAmount0; uint public lastAmount1; int24 public lastLower; int24 public lastUpper;
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    function setFails(bool f) external { fails = f; }
    function mint(MintParams calldata p) external returns (uint tokenId, uint128, uint, uint) {
        require(!fails, "pool is dead");
        // pull the tokens like the real one does
        if (p.amount0Desired > 0) require(IERC20T(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired), "pull0");
        if (p.amount1Desired > 0) require(IERC20T(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired), "pull1");
        minted++; lastAmount0 = p.amount0Desired; lastAmount1 = p.amount1Desired; lastLower = p.tickLower; lastUpper = p.tickUpper;
        return (minted, 0, p.amount0Desired, p.amount1Desired);
    }
}
interface IERC20T { function transferFrom(address, address, uint) external returns (bool); }

contract SinksTest is LegacyStackBase {
    address stack; address auction; address splitter; address rewards; address pol; MockPool poolMock; MockNPM npmMock;
    address usde = address(0xD0E);              // any address for token ordering
    address buyer = address(0xB0DE);
    uint constant LOT = 0.5 ether;
    uint constant START = 1000e18;              // 1,000 STACK per wstETH to begin with
    uint constant RATE = 1e18 / uint(1 days);  // 1 STACK per wstETH per day

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        stack = deployCode("src/testnet/MockStack.sol:MockStack");
        auction = deployCode("src/periphery/BurnAuction.sol:BurnAuction", abi.encode(stack, wst, LOT, START));
        poolMock = new MockPool(oct, usde);
        npmMock = new MockNPM();
        pol = deployCode("src/periphery/PolKeeperV3.sol:PolKeeperV3", abi.encode(wst, oct, buffer, pf, address(poolMock), address(npmMock), auction));
        splitter = deployCode("src/periphery/SurplusSplitter.sol:SurplusSplitter", abi.encode(wst, auction, pol));
        rewards = deployCode("src/periphery/ReserveRewards.sol:ReserveRewards", abi.encode(stack, buffer, RATE));
        IStackT(stack).mint(buyer, 100_000e18);
        vm.prank(buyer); IStackT(stack).approve(auction, type(uint).max);
        _open(bob, 200 ether, 100000e18);       // 500 OCT of inventory in the reserve
    }

    // --- burn auction ---

    function test_dutchAuctionBurnsStackAndDoublesTheNextStart() public {
        vm.prank(carol); IMockWst(wst).transfer(auction, 1.2 ether);
        vm.prank(buyer); vm.expectRevert(bytes("BurnAuction: nothing on offer"));
        IAuction(auction).buy(type(uint).max);                        // not notified yet
        IAuction(auction).notify();
        assertEq(IAuction(auction).lot(), LOT);
        assertEq(IAuction(auction).price(), START);
        vm.warp(block.timestamp + 24 hours);                           // halfway: 55% of the start
        assertEq(IAuction(auction).price(), START * 55 / 100);
        uint supply = IStackT(stack).totalSupply();
        vm.prank(buyer); IAuction(auction).buy(type(uint).max);
        assertEq(IMockWst(wst).balanceOf(buyer), LOT);
        assertEq(IStackT(stack).totalSupply(), supply - LOT * (START * 55 / 100) / 1e18);   // burned, not parked
        assertEq(IAuction(auction).startPrice(), START * 55 / 100 * 2);                      // next lot starts at twice the clearing price
        assertEq(IAuction(auction).lot(), LOT);                                             // 0.7 left: another full lot
        vm.warp(block.timestamp + 10 days);                            // long silence: the floor, a tenth of the start
        assertEq(IAuction(auction).price(), IAuction(auction).startPrice() / 10);
        vm.prank(buyer); vm.expectRevert(bytes("BurnAuction: price above max"));
        IAuction(auction).buy(0);
        vm.prank(buyer); IAuction(auction).buy(type(uint).max);
        vm.prank(buyer); IAuction(auction).buy(type(uint).max);        // the last 0.2
        assertTrue(IAuction(auction).empty());
        vm.prank(buyer); vm.expectRevert(bytes("BurnAuction: nothing on offer"));
        IAuction(auction).buy(type(uint).max);
    }

    // --- splitter ---

    function test_splitterHalvesAndWakesTheAuction() public {
        vm.prank(carol); IMockWst(wst).transfer(splitter, 2 ether);
        assertEq(ISplitter(splitter).pending(), 2 ether);
        (uint a, uint b) = ISplitter(splitter).split();
        assertEq(a, 1 ether); assertEq(b, 1 ether);
        assertEq(IMockWst(wst).balanceOf(auction), 1 ether);
        assertEq(IMockWst(wst).balanceOf(pol), 1 ether);
        assertFalse(IAuction(auction).empty());
        vm.expectRevert(bytes("SurplusSplitter: nothing to split"));
        ISplitter(splitter).split();
    }

    // --- reserve rewards ---

    function test_depositorsEarnStackForTimeServed() public {
        vm.prank(carol); IBuffer(buffer).deposit(10 ether);
        IStackT(stack).mint(rewards, 25e18);                          // the budget: 25 STACK
        vm.warp(block.timestamp + 2 days);                             // 20 wstETH-days = 20 STACK
        assertApproxEqAbs(IRewards(rewards).claimable(carol), 20e18, 1e9);
        vm.prank(carol); IRewards(rewards).claim();
        assertApproxEqAbs(IStackT(stack).balanceOf(carol), 20e18, 1e9);
        vm.warp(block.timestamp + 1 days);                             // 10 more, only 5 in the budget
        assertApproxEqAbs(IRewards(rewards).claimable(carol), 5e18, 1e9);
        vm.prank(carol); IRewards(rewards).claim();
        vm.prank(carol); vm.expectRevert(bytes("ReserveRewards: nothing to claim"));
        IRewards(rewards).claim();
        IStackT(stack).mint(rewards, 100e18);                         // refunded: the unpaid points are still owed
        assertApproxEqAbs(IRewards(rewards).claimable(carol), 5e18, 1e9);
    }

    // --- POL keeper ---

    function test_polWaitsBelowParDepositsAtParAndFallsBackToTheAuction() public {
        vm.prank(carol); IMockWst(wst).transfer(pol, 1 ether);
        bool octIs0 = poolMock.token0() == oct;
        poolMock.setTick(octIs0 ? int24(-50) : int24(50));           // OCT below par
        assertFalse(IPol(pol).octAtOrAbovePar());
        vm.expectRevert(bytes("PolKeeperV3: OCT below par, waiting"));
        IPol(pol).work();
        poolMock.setTick(0);                                           // at par
        uint inv0 = _inventory(); uint pot0 = _pot();
        uint octOut = IPol(pol).work();
        // 1 wstETH at $2,000 buys 1,990 OCT at par + 0.5%, capped by the 500 OCT of inventory: 500 OCT for 0.2513 wstETH
        assertEq(octOut, 500e18);
        assertEq(_inventory(), inv0 - 500e18);
        assertApproxEqAbs(_pot(), pot0 + 0.25125 ether, 1);
        assertEq(IPol(pol).positionCount(), 1);
        assertEq(IPol(pol).totalOctDeposited(), 500e18);
        assertEq(IERC20L(oct).balanceOf(address(npmMock)), 500e18);  // one-sided: all OCT
        assertEq(octIs0 ? npmMock.lastAmount1() : npmMock.lastAmount0(), 0);
        if (octIs0) { assertGt(npmMock.lastLower(), 0); } else { assertLt(npmMock.lastUpper(), 1); }
        // the venue dies: the conversion is undone and the wstETH goes to the auction
        npmMock.setFails(true);
        _open(carol, 100 ether, 100000e18);                            // fresh inventory
        uint inv1 = _inventory(); uint left = IMockWst(wst).balanceOf(pol);
        IPol(pol).work();
        assertEq(_inventory(), inv1);                                  // nothing bought
        assertEq(IMockWst(wst).balanceOf(pol), 0);
        assertEq(IPol(pol).totalCollToAuction(), left);
        assertEq(IMockWst(wst).balanceOf(auction), left);
        assertFalse(IAuction(auction).empty());
    }
}
