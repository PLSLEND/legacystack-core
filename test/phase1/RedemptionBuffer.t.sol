// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

/// Redemption Buffer (LS_06 #100-#105): revenue recipient, buffer-first redemptions, standing offer, debt ceiling.
contract RedemptionBufferTest is LegacyStackBase {

    function test_mintFeeAndInterestBecomeInventory() public {
        assertEq(_inventory(), 0);
        _open(alice, 10 ether, 5000e18);
        // 0.5% mint fee on 5,000 OCT = 25 OCT of inventory
        assertEq(_inventory(), 25e18);
        vm.warp(block.timestamp + YEAR);
        ITM(tm).accrueInterest();
        // 1.5% of 5,225 debt = 78.375 OCT more
        assertApproxEqAbs(_inventory(), 25e18 + 5225e18 * 15 / 1000, 1e6);
        _assertSupplyCoversDebt();
    }

    function test_vaultRedemptionFeeGoesToThePot() public {
        _open(alice, 4 ether, 4000e18);   // lowest ICR, will be redeemed
        _open(bob, 50 ether, 20000e18);
        assertEq(_pot(), 0);
        _redeem(bob, 5000e18);
        // 5,000 OCT at $2,000 = 2.5 wstETH drawn; fee at the 0.75% floor + baseRate lands in the pot
        uint pot = _pot();
        uint rate = ITM(tm).getRedemptionRate(); // 0.75% floor + baseRate (large here: 5,000 is 20% of this tiny supply)
        assertGt(rate, 75e14);
        assertEq(pot, 2.5 ether * rate / 1e18);
        assertEq(ITM(tm).getTroveStatus(alice), 4); // closedByRedemption
    }

    function test_bufferServesRedemptionsFirstAndKeepsTheOCT() public {
        _open(alice, 4 ether, 4000e18);   // lowest ICR
        _open(bob, 50 ether, 20000e18);
        // anyone fills the pot, no claim is created
        vm.prank(carol); IBuffer(buffer).fill(10 ether); // $20,000 of capacity
        assertEq(_pot(), 10 ether);
        assertEq(IBuffer(buffer).redeemCapacity(_price()), 20000e18);

        uint bobWstBefore = IMockWst(wst).balanceOf(bob);
        uint bobOctBefore = IERC20L(oct).balanceOf(bob);
        uint supplyBefore = IERC20L(oct).totalSupply();
        uint debtBefore = ITM(tm).getEntireSystemDebt();
        _redeem(bob, 5000e18);

        // alice's vault is untouched: the buffer served everything
        assertEq(ITM(tm).getTroveStatus(alice), 1);
        (uint debtA, uint collA,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(collA, 4 ether);
        assertEq(debtA, 4220e18);
        // bob paid 5,000 OCT and received 2.5 wstETH minus the fee
        assertEq(bobOctBefore - IERC20L(oct).balanceOf(bob), 5000e18);
        uint received = IMockWst(wst).balanceOf(bob) - bobWstBefore;
        uint rate = ITM(tm).getRedemptionRate();
        assertEq(received, 2.5 ether - 2.5 ether * rate / 1e18);
        // the OCT is inventory now, supply and debt unchanged (nothing burned)
        assertEq(_inventory(), 20e18 + 100e18 + 5000e18); // two mint fees + the redeemed OCT
        assertEq(IERC20L(oct).totalSupply(), supplyBefore);
        assertEq(ITM(tm).getEntireSystemDebt(), debtBefore);
        // the pot shrank by the net collateral only; the fee stayed
        assertEq(_pot(), 10 ether - received);
        // the brake saw the redemption: baseRate rose
        assertGt(ITM(tm).baseRate(), 0);
        _assertSupplyCoversDebt();
    }

    function test_redemptionBeyondCapacityContinuesWithVaults() public {
        _open(alice, 4 ether, 4000e18);
        _open(bob, 50 ether, 20000e18);
        vm.prank(carol); IBuffer(buffer).fill(1 ether); // $2,000 of capacity only
        uint supplyBefore = IERC20L(oct).totalSupply();
        // the hint helper knows the buffer goes first: 6,020 = 2,000 buffer + alice's whole net debt of 4,020
        (,, uint truncated) = IHintH(hh).getRedemptionHints(6020e18, _price(), 0);
        assertEq(truncated, 6020e18);
        _redeem(bob, 6020e18);
        // $2,000 from the buffer (kept as inventory), $4,020 from alice's vault (burned): alice fully redeemed
        assertEq(ITM(tm).getTroveStatus(alice), 4);
        assertEq(_inventory(), 120e18 + 2000e18);
        assertEq(supplyBefore - IERC20L(oct).totalSupply(), 4220e18); // 4,020 from bob plus the 200 gas compensation burned from the Gas Pool
        assertEq(IMockWst(wst).balanceOf(buffer) > 0, true);
        _assertSupplyCoversDebt();
    }

    function test_standingOfferSellsInventoryAtParPlusPremium() public {
        _open(alice, 10 ether, 5000e18); // 25 OCT inventory
        uint price = _price();
        uint quote = IBuffer(buffer).quoteInventory(20e18, price);
        // 20 OCT * 1.005 / 2000 = 0.01005 wstETH
        assertEq(quote, 0.01005 ether);
        uint potBefore = _pot();
        vm.prank(carol); IBuffer(buffer).buyInventory(20e18, quote);
        assertEq(IERC20L(oct).balanceOf(carol), 20e18);
        assertEq(_inventory(), 5e18);
        assertEq(_pot() - potBefore, quote);
        // max price protection
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: price above max"));
        IBuffer(buffer).buyInventory(5e18, quote / 100);
        // not more than the inventory
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: not enough inventory"));
        IBuffer(buffer).buyInventory(6e18, 1 ether);
    }

    function test_standingOfferClosedWhileOracleDegraded() public {
        _open(alice, 10 ether, 5000e18);
        IPriceT(pf).setReduceOnly(true);
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: oracle degraded, offer closed"));
        IBuffer(buffer).buyInventory(1e18, 1 ether);
    }

    function test_debtCeilingGrowsWithThePot() public {
        uint price = _price();
        assertEq(IBuffer(buffer).debtCeiling(price), 1_000_000e18);
        // give alice enough collateral to try to borrow past $1M
        IMockWst(wst).mint(alice, 2000 ether);
        vm.prank(alice); vm.expectRevert(bytes("Debt ceiling reached"));
        IBO(bo).openTrove(1e18, 1_000_000e18, address(0), address(0), 1500 ether);
        // 990,000 fits (990,000 + 4,950 fee + 200 gas comp < 1,000,000)
        vm.prank(alice); IBO(bo).openTrove(1e18, 990_000e18, address(0), address(0), 1500 ether);
        // a further 10,000 does not
        vm.prank(alice); vm.expectRevert(bytes("Debt ceiling reached"));
        IBO(bo).withdrawLUSD(1e18, 10_000e18, address(0), address(0));
        // $20,000 in the pot lifts the ceiling by $2,000,000
        vm.prank(carol); IBuffer(buffer).fill(10 ether);
        assertEq(IBuffer(buffer).debtCeiling(price), 1_000_000e18 + 2_000_000e18);
        vm.prank(alice); IBO(bo).withdrawLUSD(1e18, 10_000e18, address(0), address(0));
        _assertSupplyCoversDebt();
    }

    function test_targetAndSurplusWaterfall() public {
        _open(alice, 10 ether, 5000e18);
        _open(bob, 10 ether, 5000e18);
        // circulating supply excludes the inventory; target is 15% of it in USD
        uint circulating = IBuffer(buffer).circulatingSupply();
        assertEq(circulating, 10400e18); // 10,000 borrowed + 400 gas compensation in the Gas Pool; 50 of fees excluded
        assertEq(IBuffer(buffer).target(), 1560e18);
        uint price = _price();
        // below target: nothing
        assertEq(IBuffer(buffer).releasable(price), 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(bytes("RedemptionBuffer: nothing to release"));
        IBuffer(buffer).releaseSurplus();
        // inside the 100-200% band: half of the band is releasable, 5% of the own pot per day
        vm.prank(carol); IBuffer(buffer).fill(1 ether);          // $2,000 against a $1,560 target: band $440
        assertEq(IBuffer(buffer).releasable(price), 220e18 * 1e18 / price);
        uint released = IBuffer(buffer).releaseSurplus();
        assertEq(released, 0.05 ether);
        assertEq(IMockWst(wst).balanceOf(surplusSink), 0.05 ether);
        vm.expectRevert(bytes("RedemptionBuffer: one release per day"));
        IBuffer(buffer).releaseSurplus();
        // far above: half the band plus everything above 200%, still capped at 5% a day
        vm.prank(carol); IBuffer(buffer).fill(99.05 ether);     // own pot 100 wstETH = $200,000
        assertEq(IBuffer(buffer).releasable(price), (780e18 + 196_880e18) * 1e18 / price);
        vm.warp(block.timestamp + 1 days);
        assertEq(IBuffer(buffer).releaseSurplus(), 5 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(IBuffer(buffer).releaseSurplus(), 95 ether * 5 / 100);
    }

    function test_reserveDepositsStayTheDepositorsAndNeverFeedTheWaterfall() public {
        _open(alice, 10 ether, 5000e18);
        _open(bob, 10 ether, 5000e18);
        uint price = _price();
        vm.prank(carol); IBuffer(buffer).deposit(10 ether);
        assertEq(IBuffer(buffer).pot(), 10 ether);
        assertEq(IBuffer(buffer).ownPot(), 0);
        assertEq(IBuffer(buffer).totalDeposits(), 10 ether);
        assertEq(IBuffer(buffer).depositOf(carol), 10 ether);
        assertEq(IBuffer(buffer).releasable(price), 0);               // deposits are not surplus
        assertEq(IBuffer(buffer).debtCeiling(price), 1_000_000e18 + 2_000_000e18); // but they do lift the ceiling
        // locked for 180 days from the last deposit
        vm.warp(block.timestamp + 100 days);
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: deposit still locked"));
        IBuffer(buffer).withdraw(1 ether);
        vm.prank(carol); IBuffer(buffer).deposit(1 ether);          // extends the lock
        vm.warp(block.timestamp + 100 days);
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: deposit still locked"));
        IBuffer(buffer).withdraw(1 ether);
        vm.warp(block.timestamp + 80 days);
        // points: 10 wstETH for 100 days, then 11 wstETH for 180 days (wstETH-seconds)
        assertEq(IBuffer(buffer).pointsOf(carol), 10 ether * 100 days + 11 ether * 180 days);
        // withdrawable only while the pot stays at or above target ($1,560 = 0.78 wstETH)
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: the pot would fall below target"));
        IBuffer(buffer).withdraw(11 ether);
        uint before = IMockWst(wst).balanceOf(carol);
        vm.prank(carol); IBuffer(buffer).withdraw(10 ether);
        assertEq(IMockWst(wst).balanceOf(carol), before + 10 ether);
        assertEq(IBuffer(buffer).depositOf(carol), 1 ether);
        assertEq(IBuffer(buffer).totalDeposits(), 1 ether);
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: more than deposited"));
        IBuffer(buffer).withdraw(2 ether);
    }

    function test_onlyTroveManagerCanServe() public {
        vm.expectRevert(bytes("RedemptionBuffer: caller is not TroveManager"));
        IBufferServe(buffer).serveRedemption(alice, 1e18, 2000e18, 1e16);
    }
}

interface IBufferServe { function serveRedemption(address, uint, uint, uint) external returns (uint); }
