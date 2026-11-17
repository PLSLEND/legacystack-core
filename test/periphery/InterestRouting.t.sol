// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LiquidityDesk.t.sol";

interface IDeskV2 {
    function provide(uint, uint) external returns (uint, uint, uint);
    function provideCounter(uint) external returns (uint, uint);
    function provideOct(uint) external returns (uint, uint);
    function withdraw(uint128) external returns (uint, uint);
    function withdrawBid(uint128) external returns (uint, uint);
    function withdrawAsk(uint128) external returns (uint, uint);
    function claim() external returns (uint);
    function collect() external returns (uint, uint);
    function inherit(address) external;
    function notifyReward(uint) external;
    function positionOf(address) external view returns (uint);
    function bidOf(address) external view returns (uint);
    function askOf(address) external view returns (uint);
    function hasPositions(address) external view returns (bool);
    function rewardOf(address) external view returns (uint);
    function bidLiquidityOf(address) external view returns (uint128);
    function totalBidLiquidity() external view returns (uint128);
    function rewardAccounted() external view returns (uint);
    function octInPositions() external view returns (uint);
    function bidPlaceable() external view returns (bool);
    function askPlaceable() external view returns (bool);
    function rangeOf(uint8) external view returns (int24, int24);
    function askLower() external view returns (int24);
    function bidTicks() external view returns (int24);
}
interface ISplitterT { function split() external returns (uint, uint, uint); function pending() external view returns (uint); function totalToBuffer() external view returns (uint); }
interface IIssuanceT { function pending() external view returns (uint); function accounted() external view returns (uint); function paidOut() external view returns (uint); function issueLQTY() external returns (uint); }
interface ISPGain { function getDepositorLQTYGain(address) external view returns (uint); }

/// The interest's route (#177): TroveManager mints it to the splitter; half to the Stability Pool's depositors
/// through the issuance contract, half to the desk's bids; what has no taker goes to the buffer's inventory.
contract InterestRoutingTest is LegacyStackBase {
    address desk; address usde; DeskPoolMock poolMock; DeskNPMMock npmMock; address splitter;

    function _interestRecipient() internal override returns (address) {
        usde = deployCode("src/testnet/MockUSDe.sol:MockUSDe");
        poolMock = new DeskPoolMock(oct, usde);
        npmMock = new DeskNPMMock();
        desk = deployCode("src/periphery/LiquidityDesk.sol:LiquidityDesk", abi.encode(oct, address(poolMock), address(npmMock), registry));
        issuance = deployCode("src/periphery/InterestIssuance.sol:InterestIssuance", abi.encode(oct, sp));   // replaces the stub in the pool
        splitter = deployCode("src/periphery/InterestSplitter.sol:InterestSplitter", abi.encode(oct, sp, issuance, desk, buffer));
        return splitter;
    }

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        _open(alice, 40 ether, 20000e18);
        _open(bob, 80 ether, 40000e18);
        IERC20D(usde).mint(bob, 10000e18); IERC20D(usde).mint(carol, 10000e18);
        address[3] memory us = [alice, bob, carol];
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(us[i]);
            IERC20D(oct).approve(desk, type(uint).max); IERC20D(usde).approve(desk, type(uint).max); IERC20D(oct).approve(sp, type(uint).max);
            vm.stopPrank();
        }
    }

    function _accrueYear() internal returns (uint minted) {
        uint before = IERC20L(oct).balanceOf(splitter);
        vm.warp(block.timestamp + 365 days);
        ITM(tm).accrueInterest();
        minted = IERC20L(oct).balanceOf(splitter) - before;
    }

    function test_theInterestIsMintedToTheSplitterAndGoesToTheBufferWhenNobodyIsThereToBePaid() public {
        assertEq(ITM(tm).interestRecipientAddress(), splitter);
        uint minted = _accrueYear();
        assertApproxEqRel(minted, 900e18, 0.02e18, "1.5% of 60,000 of debt, in a year");   // the opening fees add a little
        assertEq(ISplitterT(splitter).pending(), minted);
        uint inv = IBuffer(buffer).inventory();
        (uint toPool, uint toDesk, uint toBuffer) = ISplitterT(splitter).split();
        assertEq(toPool, 0); assertEq(toDesk, 0); assertEq(toBuffer, minted, "no deposits, no bids: the buffer keeps it");
        assertEq(IBuffer(buffer).inventory() - inv, minted);
        assertEq(ISplitterT(splitter).pending(), 0);
        (toPool, toDesk, toBuffer) = ISplitterT(splitter).split();
        assertEq(toPool + toDesk + toBuffer, 0, "nothing twice");
    }

    function test_aChainWithoutADeskSendsTheDesksHalfToTheBuffer() public {
        // mainnet's venue may not be a Uniswap v3 pool: the splitter is built with no desk and still routes the pool's half
        address lone = deployCode("src/periphery/InterestSplitter.sol:InterestSplitter", abi.encode(oct, sp, issuance, address(0), buffer));
        vm.prank(alice); ISP(sp).provideToSP(10000e18);
        vm.prank(bob); IERC20L(oct).transfer(lone, 1000e18);           // stands in for the minted interest
        uint inv = IBuffer(buffer).inventory();
        (uint toPool, uint toDesk, uint toBuffer) = ISplitterT(lone).split();
        assertEq(toPool, 500e18, "the pool's half is issued to its depositors");
        assertEq(toDesk, 0); assertEq(toBuffer, 500e18, "no desk: the other half is the buffer's");
        assertEq(IBuffer(buffer).inventory() - inv, 500e18);
        assertEq(IIssuanceT(issuance).pending(), 500e18);
    }

    function test_halfToThePoolsDepositorsHalfToTheBids() public {
        vm.prank(alice); ISP(sp).provideToSP(10000e18);
        vm.prank(bob); (uint bidId, uint used) = IDeskV2(desk).provideCounter(5000e18);
        assertEq(used, 5000e18); assertEq(IDeskV2(desk).bidOf(bob), bidId);
        assertEq(IDeskV2(desk).totalBidLiquidity(), 5000e18);
        (int24 lower, int24 upper) = IDeskV2(desk).rangeOf(1);
        if (poolMock.token0() == oct) { assertEq(lower, -50); assertEq(upper, 0); } else { assertEq(lower, 0); assertEq(upper, 50); }
        assertEq(npmMock.lastLower(), lower); assertEq(npmMock.lastUpper(), upper);

        uint minted = _accrueYear();
        (uint toPool, uint toDesk, uint toBuffer) = ISplitterT(splitter).split();
        assertEq(toBuffer, 0);
        assertEq(toPool, minted / 2); assertEq(toDesk, minted - toPool);
        assertEq(IIssuanceT(issuance).pending(), toPool, "waits in the issuance contract for the pool's next operation");
        assertEq(IDeskV2(desk).rewardOf(bob), toDesk, "the only bid earns the desk's whole half");
        assertEq(IDeskV2(desk).rewardAccounted(), toDesk);

        // the pool's next operation books the issuance to the depositors of that moment: alice alone
        vm.prank(carol); IERC20D(oct).transfer(alice, 0);
        vm.prank(bob); ISP(sp).provideToSP(100e18);
        assertApproxEqAbs(ISPGain(sp).getDepositorLQTYGain(alice), toPool, 1e6, "alice is owed the pool's half");
        assertEq(ISPGain(sp).getDepositorLQTYGain(bob), 0, "bob came after");
        assertEq(IIssuanceT(issuance).pending(), 0);
        uint aliceBefore = IERC20L(oct).balanceOf(alice);
        vm.prank(alice); ISP(sp).withdrawFromSP(0);
        assertApproxEqAbs(IERC20L(oct).balanceOf(alice) - aliceBefore, toPool, 1e6, "paid in OCT on the next touch");
        assertApproxEqAbs(IIssuanceT(issuance).paidOut(), toPool, 1e6);

        // the bid claims its income
        uint bobBefore = IERC20L(oct).balanceOf(bob);
        vm.prank(bob); uint claimed = IDeskV2(desk).claim();
        assertEq(claimed, toDesk); assertEq(IERC20L(oct).balanceOf(bob) - bobBefore, toDesk);
        assertEq(IDeskV2(desk).rewardOf(bob), 0); assertEq(IDeskV2(desk).rewardAccounted(), 0);
        vm.prank(bob); vm.expectRevert("LiquidityDesk: nothing to claim"); IDeskV2(desk).claim();

        // a second bid shares the next year pro rata to its liquidity
        vm.prank(carol); IDeskV2(desk).provideCounter(10000e18);
        uint minted2 = _accrueYear();
        (, uint toDesk2,) = ISplitterT(splitter).split();
        assertEq(toDesk2, minted2 - minted2 / 2);
        assertApproxEqAbs(IDeskV2(desk).rewardOf(bob), toDesk2 / 3, 1e6);
        assertApproxEqAbs(IDeskV2(desk).rewardOf(carol), toDesk2 * 2 / 3, 1e6);
    }

    function test_theFirstDepositorDoesNotStrandOctThatArrivedWhileThePoolWasEmpty() public {
        // OCT reaches the issuance contract while the pool is empty (a direct gift here)
        vm.prank(alice); IERC20L(oct).transfer(issuance, 300e18);
        assertEq(IIssuanceT(issuance).pending(), 300e18);
        vm.prank(alice); ISP(sp).provideToSP(1000e18);           // the trigger ran with zero deposits: nothing issued
        assertEq(IIssuanceT(issuance).pending(), 300e18);
        assertEq(ISPGain(sp).getDepositorLQTYGain(alice), 0);
        vm.prank(bob); ISP(sp).provideToSP(1000e18);             // the next trigger issues it to alice, the depositor of record
        assertApproxEqAbs(ISPGain(sp).getDepositorLQTYGain(alice), 300e18, 1e6);
        assertEq(IIssuanceT(issuance).pending(), 0);
        vm.expectRevert("InterestIssuance: caller is not the Stability Pool");
        IIssuanceT(issuance).issueLQTY();
    }

    function test_aBidBuysOctWhenItIsSoldAndUnwindsWithBothSidesAndItsIncome() public {
        vm.prank(bob); (uint bidId,) = IDeskV2(desk).provideCounter(5000e18);
        // a seller crosses the bid: 2,000 OCT in, 2,000 USDe out
        vm.prank(alice); IERC20L(oct).approve(address(npmMock), type(uint).max);
        npmMock.fill(bidId, poolMock.token0() == oct, 2000e18, alice);
        assertEq(IERC20D(usde).balanceOf(alice), 2000e18, "the seller got dollars at par");
        // the bid still earns while it holds OCT; a year of interest, split
        vm.prank(alice); ISP(sp).provideToSP(1000e18);
        uint minted = _accrueYear();
        (, uint toDesk,) = ISplitterT(splitter).split();
        assertEq(IDeskV2(desk).rewardOf(bob), toDesk);
        uint o = IERC20L(oct).balanceOf(bob); uint u = IERC20D(usde).balanceOf(bob);
        vm.prank(bob); (uint octOut, uint usdeOut) = IDeskV2(desk).withdrawBid(0);
        assertEq(octOut, 2000e18); assertEq(usdeOut, 3000e18);
        assertEq(IERC20L(oct).balanceOf(bob) - o, 2000e18 + toDesk, "the OCT it bought plus the income");
        assertEq(IERC20D(usde).balanceOf(bob) - u, 3000e18);
        assertEq(IDeskV2(desk).bidOf(bob), 0); assertEq(IDeskV2(desk).totalBidLiquidity(), 0);
        // with no bids left, the next split has no taker on the desk's side
        _accrueYear();
        (uint toPool2, uint toDesk2, uint toBuffer2) = ISplitterT(splitter).split();
        assertGt(toPool2, 0); assertEq(toDesk2, 0); assertEq(toBuffer2, toPool2, "the desk's half went to the buffer");
    }

    function test_bidsWaitUnderParAndAsksWaitAboveTheOffer() public {
        poolMock.setTick(-10);                                   // OCT at 0.999: a bid range would straddle the price
        assertFalse(IDeskV2(desk).bidPlaceable());
        vm.prank(bob); vm.expectRevert("LiquidityDesk: OCT is under par right now, wait"); IDeskV2(desk).provideCounter(1000e18);
        assertTrue(IDeskV2(desk).askPlaceable());
        vm.prank(alice); (uint askId, uint used) = IDeskV2(desk).provideOct(1000e18);
        assertEq(used, 1000e18); assertEq(IDeskV2(desk).askOf(alice), askId);
        (int24 lower, int24 upper) = IDeskV2(desk).rangeOf(2);
        if (poolMock.token0() == oct) { assertEq(lower, 50); assertEq(upper, 200); } else { assertEq(lower, -200); assertEq(upper, -50); }
        assertEq(IDeskV2(desk).octInPositions(), 1000e18, "asks count as parked OCT for the POL target");
        assertEq(IDeskV2(desk).rewardOf(alice), 0, "asks earn fees, not the interest");
        poolMock.setTick(80);                                    // OCT at 1.008: inside the ask range, the ask waits
        assertFalse(IDeskV2(desk).askPlaceable());
        vm.prank(alice); vm.expectRevert("LiquidityDesk: OCT is above the offer right now, wait"); IDeskV2(desk).provideOct(1e18);
        assertTrue(IDeskV2(desk).bidPlaceable());
        vm.prank(alice); (uint octOut,) = IDeskV2(desk).withdrawAsk(0);
        assertEq(octOut, 1000e18); assertEq(IDeskV2(desk).octInPositions(), 0);
    }

    function test_everyPositionAndTheIncomePassToTheHeirs() public {
        IERC20D(usde).mint(alice, 5000e18);
        vm.prank(alice); IDeskV2(desk).provide(1000e18, 1000e18);
        vm.prank(alice); IDeskV2(desk).provideCounter(4000e18);
        vm.prank(alice); IDeskV2(desk).provideOct(500e18);
        vm.prank(bob); ISP(sp).provideToSP(1000e18);
        uint minted = _accrueYear();
        (, uint toDesk,) = ISplitterT(splitter).split();
        assertEq(IDeskV2(desk).rewardOf(alice), toDesk);
        address[] memory heirs = new address[](2); heirs[0] = carol; heirs[1] = dave;
        uint16[] memory bps = new uint16[](2); bps[0] = 7000; bps[1] = 3000;
        vm.prank(alice); IRegistry(registry).setPlan(heirs, bps, address(0));
        vm.expectRevert("LiquidityDesk: the plan is not executed"); IDeskV2(desk).inherit(alice);
        vm.warp(block.timestamp + 395 days + 1);
        vm.prank(bob); ISP(sp).provideToSP(29000e18);
        IRegistry(registry).execute(alice);
        (uint8 state,,) = IRegistry(registry).successionState(alice);
        assertEq(state, 4, "the estate is settled");
        uint cO = IERC20L(oct).balanceOf(carol); uint dO = IERC20L(oct).balanceOf(dave);
        uint cU = IERC20D(usde).balanceOf(carol); uint dU = IERC20D(usde).balanceOf(dave);
        IDeskV2(desk).inherit(alice);
        uint octTotal = 1000e18 + 500e18 + toDesk; uint usdeTotal = 1000e18 + 4000e18;
        assertEq(IERC20L(oct).balanceOf(carol) - cO, octTotal * 7000 / 10000);
        assertEq(IERC20L(oct).balanceOf(dave) - dO, octTotal - octTotal * 7000 / 10000);
        assertEq(IERC20D(usde).balanceOf(carol) - cU, usdeTotal * 7000 / 10000);
        assertEq(IERC20D(usde).balanceOf(dave) - dU, usdeTotal - usdeTotal * 7000 / 10000);
        assertFalse(IDeskV2(desk).hasPositions(alice));
        assertEq(IDeskV2(desk).rewardOf(alice), 0); assertEq(IDeskV2(desk).rewardAccounted(), 0);
        assertEq(IDeskV2(desk).totalBidLiquidity(), 0); assertEq(IDeskV2(desk).octInPositions(), 0);
    }

    function test_theKeeperDeskRoutesTheInterestInItsHousekeepingPress() public {
        address keeper = deployCode("src/periphery/KeeperDesk.sol:KeeperDesk", abi.encode(tm, bo, st, pf, buffer, registry, oct, wst, desk));
        vm.prank(alice); ISP(sp).provideToSP(5000e18);
        vm.prank(bob); IDeskV2(desk).provideCounter(5000e18);
        vm.warp(block.timestamp + 365 days);
        address[] memory none;
        vm.prank(dave); IKeeperRun(keeper).run(none, none, none, true);
        assertEq(ISplitterT(splitter).pending(), 0, "split in the press");
        assertGt(IIssuanceT(issuance).pending(), 0); assertGt(IDeskV2(desk).rewardOf(bob), 0);
    }
}
