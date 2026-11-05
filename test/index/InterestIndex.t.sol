// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

contract InterestIndexTest is LegacyStackBase {
    function test_interestAccruesAtOneAndAHalfPercent() public {
        _open(alice, 10 ether, 5000e18);
        (uint debt0,,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(debt0, 5225e18);
        vm.warp(block.timestamp + YEAR);
        // view reflects accrual before any touch
        (uint debt1,,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertApproxEqAbs(debt1, 5225e18 * 1015 / 1000, 1e6);
        assertApproxEqAbs(ITM(tm).currentRateIndex(), 1.015e18, 1);
        // touch: interest is minted to the fee sink
        uint sinkBefore = IERC20L(oct).balanceOf(buffer);
        ITM(tm).accrueInterest();
        uint minted = IERC20L(oct).balanceOf(buffer) - sinkBefore;
        assertApproxEqAbs(minted, 5225e18 * 15 / 1000, 1e6);
        _assertSupplyCoversDebt();
    }

    function test_repayAndCloseAfterInterest() public {
        _open(alice, 10 ether, 5000e18);
        _open(bob, 20 ether, 10000e18);
        vm.warp(block.timestamp + YEAR);
        ITM(tm).accrueInterest();
        (uint debtA,,,) = ITM(tm).getEntireDebtAndColl(alice);
        // alice needs debt - 200 (gas comp) OCT to close; she holds 5000, buys the rest from the sink and bob
        uint need = debtA - 200e18;
        uint have = IERC20L(oct).balanceOf(alice);
        uint sinkBal = IERC20L(oct).balanceOf(buffer);
        _takeFromBuffer(alice, sinkBal);
        uint aliceBal = IERC20L(oct).balanceOf(alice);
        if (aliceBal < need) { vm.prank(bob); IERC20L(oct).transfer(alice, need - aliceBal); }
        assertGe(IERC20L(oct).balanceOf(alice), need);
        vm.prank(alice); IBO(bo).closeTrove();
        assertEq(ITM(tm).getTroveStatus(alice), 2);
        assertEq(ITM(tm).getTroveNormalizedDebt(alice), 0);
        _assertSupplyCoversDebt();
        have; // silence
    }

    function test_partialRepayAndBorrowBetweenAccruals() public {
        _open(alice, 10 ether, 5000e18);
        vm.warp(block.timestamp + 100 days);
        _open(bob, 20 ether, 8000e18);           // touches the index
        vm.warp(block.timestamp + 200 days);
        vm.prank(alice); IBO(bo).repayLUSD(1000e18, address(0), address(0));
        vm.warp(block.timestamp + 65 days);
        vm.prank(bob); IBO(bo).withdrawLUSD(1e18, 500e18, address(0), address(0));
        _assertSupplyCoversDebt();
        // alice: 5225 for 100d, then compounding at bob's touch, repay 1000, then 265 more days of interest
        (uint debtA,,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertGt(debtA, 4225e18);
        assertLt(debtA, 4225e18 * 102 / 100);
    }

    function test_redistributionCarriesInterest() public {
        _open(bob, 50 ether, 20000e18);
        _open(alice, 3 ether, 4000e18);          // ICR 142%
        // no SP deposits: liquidation redistributes
        IPriceT(pf).setPrice(1500e18);
        vm.prank(carol); ITM(tm).liquidate(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 3);
        uint pendingBob = ITM(tm).getPendingLUSDDebtReward(bob);
        assertGt(pendingBob, 0);
        _assertSupplyCoversDebt();
        vm.warp(block.timestamp + YEAR);
        // pending debt accrues interest like any other debt
        uint pendingBobLater = ITM(tm).getPendingLUSDDebtReward(bob);
        assertApproxEqAbs(pendingBobLater, pendingBob * 1015 / 1000, 1e6);
        // applying the rewards (via any adjustment) keeps the invariant
        vm.prank(bob); IBO(bo).addColl(address(0), address(0), 1 ether);
        _assertSupplyCoversDebt();
        assertEq(ITM(tm).getPendingLUSDDebtReward(bob), 0);
    }

    function test_stabilityPoolOffsetAfterInterest() public {
        _open(bob, 50 ether, 20000e18);
        vm.prank(bob); ISP(sp).provideToSP(15000e18, address(0));
        _open(alice, 3 ether, 4000e18);
        vm.warp(block.timestamp + 180 days);
        IPriceT(pf).setPrice(1500e18);
        vm.prank(carol); ITM(tm).liquidate(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 3);
        _assertSupplyCoversDebt();
    }

    function test_thirtyYearsPrecision() public {
        _open(alice, 100 ether, 50000e18);
        (uint debt0,,,) = ITM(tm).getEntireDebtAndColl(alice); // 50000 + 200 gas comp + 250 fee
        for (uint i = 0; i < 30; i++) {
            vm.warp(block.timestamp + YEAR);
            ITM(tm).accrueInterest();
            _assertSupplyCoversDebt();
        }
        (uint debtA,,,) = ITM(tm).getEntireDebtAndColl(alice);
        // yearly compounding at 1.5% for 30 years: x1.5631
        assertApproxEqRel(debtA, debt0 * 15631 / 10000, 0.001e18);
    }

    function testFuzz_randomOpsKeepSupplyCoveringDebt(uint seed) public {
        _open(bob, 200 ether, 50000e18);
        vm.prank(bob); ISP(sp).provideToSP(20000e18, address(0));
        address[3] memory users = [alice, carol, dave];
        for (uint i = 0; i < 12; i++) {
            uint r = uint(keccak256(abi.encode(seed, i)));
            address u = users[r % 3];
            uint action = (r >> 8) % 5;
            vm.warp(block.timestamp + ((r >> 16) % 90 days));
            uint status = ITM(tm).getTroveStatus(u);
            if (status != 1) {
                uint amount = 2000e18 + ((r >> 32) % 8000e18);
                uint coll = amount * 2 / 2000 + 1 ether; // ~200%+ ICR at $2000
                vm.prank(u); IBO(bo).openTrove(1e18, amount, address(0), address(0), coll);
            } else if (action == 0) {
                vm.prank(u); IBO(bo).addColl(address(0), address(0), 1 ether);
            } else if (action == 1) {
                uint bal = IERC20L(oct).balanceOf(u);
                (uint d,,,) = ITM(tm).getEntireDebtAndColl(u);
                uint repay = bal / 4;
                if (repay > 0 && d - repay >= 2000e18) { vm.prank(u); IBO(bo).repayLUSD(repay, address(0), address(0)); }
            } else if (action == 2) {
                vm.prank(u); IBO(bo).withdrawLUSD(1e18, 300e18, address(0), address(0));
            } else if (action == 3) {
                ITM(tm).accrueInterest();
            } else {
                // close if affordable
                (uint d,,,) = ITM(tm).getEntireDebtAndColl(u);
                uint bal = IERC20L(oct).balanceOf(u);
                if (bal >= d - 200e18) { vm.prank(u); IBO(bo).closeTrove(); }
            }
            _assertSupplyCoversDebt();
        }
    }
}

contract CollateralFlowsTest is InterestIndexTest {
    function test_stabilityPoolGainsFlowAsTokens() public {
        _open(bob, 50 ether, 20000e18);
        vm.prank(bob); ISP(sp).provideToSP(15000e18, address(0));
        _open(alice, 3 ether, 4000e18);
        IPriceT(pf).setPrice(1500e18);
        vm.prank(carol); ITM(tm).liquidate(alice);
        // bob's SP deposit absorbed alice's debt and earned her collateral (minus 0.5% to the liquidator)
        uint wstBefore = IMockWst(wst).balanceOf(bob);
        vm.prank(bob); ISP(sp).withdrawFromSP(0); // claims gains only
        uint gain = IMockWst(wst).balanceOf(bob) - wstBefore;
        assertApproxEqRel(gain, 3 ether * 995 / 1000, 0.01e18);
        assertGt(IMockWst(wst).balanceOf(carol), 1000 ether); // liquidator got 0.5% of 3 wstETH
        _assertSupplyCoversDebt();
    }

    function test_withdrawGainToTroveAndCollSurplusClaim() public {
        _open(bob, 50 ether, 20000e18);
        vm.prank(bob); ISP(sp).provideToSP(15000e18, address(0));
        _open(alice, 3 ether, 4000e18);
        IPriceT(pf).setPrice(1500e18);
        vm.prank(carol); ITM(tm).liquidate(alice);
        (, uint collBefore,,) = ITM(tm).getEntireDebtAndColl(bob);
        vm.prank(bob); ISP(sp).withdrawETHGainToTrove(address(0), address(0));
        (, uint collAfter,,) = ITM(tm).getEntireDebtAndColl(bob);
        assertGt(collAfter, collBefore);
        _assertSupplyCoversDebt();
    }
}
