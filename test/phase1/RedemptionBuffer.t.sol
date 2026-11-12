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

/// Fee sharing with reserve depositors and the deposit's succession (LS_06 #171).
contract ReserveFeeSharingTest is LegacyStackBase {

    function test_depositorsEarnTheirShareOfRedemptionFeesAtLeastHalf() public {
        _open(alice, 4 ether, 4000e18);
        _open(bob, 50 ether, 20000e18);
        // the protocol's own pot is 30 wstETH (a fill), carol deposits 10: her share of the pot is 25%, floored at 50%
        vm.prank(dave); IBuffer(buffer).fill(30 ether);
        vm.prank(carol); IBuffer(buffer).deposit(10 ether);
        assertEq(IBuffer(buffer).depositorsShareBps(), 5000);
        assertEq(IBuffer(buffer).feesOf(carol), 0);
        // a redemption served by the reserve: the fee stays in the pot, half of it set aside for carol
        uint potBefore = IBuffer(buffer).pot();
        _redeem(bob, 5000e18);
        uint rate = ITM(tm).getRedemptionRate();
        uint fee = 2.5 ether * rate / 1e18;
        assertEq(IBuffer(buffer).feesOwed(), fee / 2);
        assertApproxEqAbs(IBuffer(buffer).feesOf(carol), fee / 2, 1e3);
        assertEq(IBuffer(buffer).totalFeesShared(), fee / 2);
        // the reserve's capital counts the fee, minus what is owed
        assertEq(IBuffer(buffer).pot(), potBefore - (2.5 ether - fee) - fee / 2);
        assertEq(_pot(), IBuffer(buffer).pot() + fee / 2, "held = capital + owed");
        // claimable at once, in wstETH, whatever the target says
        uint before = IMockWst(wst).balanceOf(carol);
        vm.prank(carol); uint got = IBuffer(buffer).claimFees();
        assertApproxEqAbs(got, fee / 2, 1e3);
        assertEq(IMockWst(wst).balanceOf(carol), before + got);
        assertEq(IBuffer(buffer).feesOf(carol), 0);
        assertApproxEqAbs(IBuffer(buffer).feesOwed(), 0, 1e3, "dust only");
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: nothing to claim"));
        IBuffer(buffer).claimFees();
    }

    function test_shareFollowsTheDepositorsPartOfThePotAboveHalf() public {
        _open(alice, 4 ether, 4000e18);
        _open(bob, 50 ether, 20000e18);
        // carol holds 80% of the pot: she gets 80% of the fees; dave, who deposited later, gets his part of what came after
        vm.prank(dave); IBuffer(buffer).fill(2 ether);
        vm.prank(carol); IBuffer(buffer).deposit(8 ether);
        assertEq(IBuffer(buffer).depositorsShareBps(), 8000);
        _redeem(bob, 5000e18);
        uint fee1 = 2.5 ether * ITM(tm).getRedemptionRate() / 1e18;
        assertApproxEqAbs(IBuffer(buffer).feesOf(carol), fee1 * 8000 / 10000, 1e3);
        vm.warp(block.timestamp + 2 days);                 // the baseRate decays, the next fee is a fresh one
        vm.prank(dave); IBuffer(buffer).deposit(8 ether);  // now two depositors, 16 of ~17.3 in the pot
        _redeem(bob, 5000e18);
        uint fee2 = 2.5 ether * ITM(tm).getRedemptionRate() / 1e18;
        uint share = IBuffer(buffer).depositorsShareBps();
        assertGt(share, 9000);
        uint part2 = fee2 * share / 10000;
        assertApproxEqAbs(IBuffer(buffer).feesOf(dave), part2 / 2, 1e3, "dave: half of the second fee");
        assertApproxEqAbs(IBuffer(buffer).feesOf(carol), fee1 * 8000 / 10000 + part2 / 2, 1e3, "carol: the first, half of the second");
    }

    function test_vaultRedemptionFeeAndOfferPremiumAreSharedToo() public {
        _open(alice, 4 ether, 4000e18);   // lowest ICR, redeemed from
        _open(bob, 50 ether, 20000e18);
        vm.prank(carol); IBuffer(buffer).deposit(1 ether);
        // the pot holds only carol's 1 wstETH ($2,000): the redemption goes to the vaults beyond that capacity;
        // the fee of the vault part arrives in the pot and is shared (carol is 100% of the pot: all of it)
        _redeem(bob, 5000e18);
        uint fee = IBuffer(buffer).feesOwed();
        assertGt(fee, 0);
        assertEq(IBuffer(buffer).feesOf(carol), fee);
        // the standing offer: bob buys 100 OCT of inventory at par + 0.5%; the premium is shared the same way
        uint quote = IBuffer(buffer).quoteInventory(100e18, _price());
        uint par = 100e18 * 1e18 / _price();
        vm.prank(bob); IMockWst(wst).approve(buffer, type(uint).max);
        vm.prank(bob); IBuffer(buffer).buyInventory(100e18, quote);
        assertEq(IBuffer(buffer).feesOf(carol), fee + (quote - par), "the premium above par, all of it");
    }

    function test_depositPassesToTheHeirsAsADepositWithItsFeesAndPoints() public {
        _open(bob, 50 ether, 20000e18);
        _open(alice, 4 ether, 4000e18);
        vm.prank(alice); IBuffer(buffer).deposit(10 ether);
        address[] memory heirs = new address[](2); heirs[0] = carol; heirs[1] = dave;
        uint16[] memory bps = new uint16[](2); bps[0] = 7000; bps[1] = 3000;
        vm.prank(alice); IRegistry(registry).setPlan(heirs, bps, address(0));
        _redeem(bob, 5000e18);                                 // alice earns fees as the only depositor
        uint fees = IBuffer(buffer).feesOf(alice);
        assertGt(fees, 0);
        uint lock = IBuffer(buffer).lockedUntil(alice);
        // a year of silence and thirty days of grace; nobody can move the deposit before that
        vm.expectRevert(bytes("RedemptionBuffer: caller is not the SuccessionRegistry"));
        IBuffer(buffer).transferDepositForSuccession(alice, carol, 1 ether);
        vm.warp(block.timestamp + 395 days + 1);
        uint points = IBuffer(buffer).pointsOf(alice);
        uint potBefore = _pot();
        IRegistry(registry).execute(alice);
        // nothing left the reserve (the settlement even paid collateral in); the deposit, its fees and its
        // points are the heirs' now, 70/30
        assertGe(_pot(), potBefore, "nothing left the reserve");
        assertEq(IBuffer(buffer).depositOf(alice), 0);
        assertEq(IBuffer(buffer).depositOf(carol), 7 ether);
        assertEq(IBuffer(buffer).depositOf(dave), 3 ether);
        assertEq(IBuffer(buffer).totalDeposits(), 10 ether);
        assertEq(IBuffer(buffer).feesOf(alice), 0);
        assertApproxEqAbs(IBuffer(buffer).feesOf(carol), fees * 7 / 10, 1);
        assertApproxEqAbs(IBuffer(buffer).feesOf(dave), fees * 3 / 10, 1);
        assertApproxEqAbs(IBuffer(buffer).pointsOf(carol), points * 7 / 10, 1e9);
        assertEq(IBuffer(buffer).lockedUntil(carol), lock, "the heir inherits the lock");
        // the heirs act for themselves from here: carol claims her fees, and may withdraw once the pot allows
        vm.prank(carol); uint got = IBuffer(buffer).claimFees();
        assertApproxEqAbs(got, fees * 7 / 10, 1);
        (uint8 state,,) = IRegistry(registry).successionState(alice);
        assertEq(state, 4);
    }

}
