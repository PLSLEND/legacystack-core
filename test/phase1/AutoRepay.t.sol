// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IBOAuto {
    function setAutoRepay(uint8) external;
    function skimYield(address, address, address) external;
    function autoRepay(address) external view returns (uint8 cadence, uint64 lastSkim, uint baseline);
    function SKIM_CUT_CAP() external view returns (uint);
    function SHARE_BPS() external view returns (uint);
    function SHARE_AUTO_BPS() external view returns (uint);
    function SHARE_CUT_BPS() external view returns (uint);
    function SHARE_CUT_CAP() external view returns (uint);
}

/// Auto-repay from staking rewards (LS_06 #160, #161, #177): the yield above the baseline is split; the
/// protocol's share (15% of a regular vault's yield, 10% with auto-repay on) goes to the buffer's pot in wstETH,
/// the rest is sold to the buffer's standing offer and the OCT repays the vault. Owner any time without a cut;
/// keepers on the cadence, only when the yield covers the period's interest, for 1% capped at 5 OCT; on a
/// regular vault anyone may take the protocol's share alone for 10% of it, capped at 0.02 wstETH.
contract AutoRepayTest is LegacyStackBase {
    address keeper = address(0xBEEF);
    uint constant RATE0 = 1.2e18;
    uint constant MIN_NET_DEBT_PLUS_GAS = 1800e18 + 200e18;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        _open(bob, 200 ether, 200000e18);   // bob's mint fee (1,000 OCT) is the reserve's first inventory
    }

    function _rate(uint r) internal { IMockWst(wst).setStEthPerToken(r); }
    function _baseline(address who) internal view returns (uint b) { (,, b) = IBOAuto(bo).autoRepay(who); }
    function _vault(address who) internal view returns (uint debt, uint coll) { (debt, coll,,) = ITM(tm).getEntireDebtAndColl(who); }

    // --- baseline accounting ---

    function test_depositsAndWithdrawalsAreNotYield() public {
        _open(alice, 10 ether, 5000e18);
        assertEq(_baseline(alice), 10 ether * RATE0 / 1e18);            // 12 stETH
        vm.prank(alice); IBO(bo).addColl(address(0), address(0), 5 ether);
        assertEq(_baseline(alice), 15 ether * RATE0 / 1e18);
        vm.prank(alice); IBO(bo).withdrawColl(2 ether, address(0), address(0));
        assertEq(_baseline(alice), 13 ether * RATE0 / 1e18);
        // no rate growth, nothing to skim, even for the owner
        vm.prank(alice); vm.expectRevert(bytes("no yield yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // the rate grows 2%: the yield is exactly the wstETH above 13 wstETH-at-the-old-rate
        _rate(RATE0 * 102 / 100);
        (, uint coll) = _vault(alice);
        uint expectedYield = coll - (13 ether * RATE0 / 1e18) * 1e18 / (RATE0 * 102 / 100);
        assertApproxEqAbs(expectedYield, uint(13 ether) - uint(13 ether) * 100 / 102, uint(2));
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (, uint collAfter) = _vault(alice);
        assertApproxEqAbs(coll - collAfter, expectedYield, 1e12);        // the quote rounds the collateral by a wei
        // the vault's stETH value is back at the baseline: nothing more to skim
        vm.prank(alice); vm.expectRevert(bytes("no yield yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
    }

    // --- the owner's skim ---

    function test_ownerSkimsAnyTimeWithoutACut() public {
        _open(alice, 10 ether, 5000e18);
        _rate(RATE0 * 104 / 100);                                        // +4%
        (uint debt0, uint coll0) = _vault(alice);
        uint inv0 = _inventory(); uint pot0 = _pot(); uint octBefore = IERC20L(oct).balanceOf(alice);
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (uint debt1, uint coll1) = _vault(alice);
        uint collSold = coll0 - coll1;
        uint octBought = inv0 - _inventory();
        // 10 - 10/1.04 = 0.3846 wstETH of yield leaves the vault: 15% is the protocol's share, the other 85%
        // (0.3269 wstETH at $2,000) buys 653.8 / 1.005 = 650.6 OCT, all repaid
        assertApproxEqRel(collSold, 0.3846e18, 1e15);
        assertApproxEqRel(octBought, 650.6e18, 1e15);
        assertApproxEqAbs(debt0 - debt1, octBought, 1e6);
        assertEq(_pot(), pot0 + collSold);                                // all of it is in the buffer: the sale and the share
        assertEq(IERC20L(oct).balanceOf(alice), octBefore);              // no cut, nothing to the owner
        assertEq(IERC20L(oct).balanceOf(keeper), 0);
        // the ratio improved
        assertGt(ITM(tm).getCurrentICR(alice, _price()), coll0 * _price() / debt0);
        _assertSupplyCoversDebt();
    }

    function test_repaymentNeverGoesBelowTheMinimumDebtTheRestIsTheOwners() public {
        _open(alice, 100 ether, 1800e18);                                // net debt at the minimum plus the 9 OCT fee
        _rate(RATE0 * 110 / 100);                                        // +10%: ~9.1 wstETH of yield, ~$18k
        (uint debt0,) = _vault(alice); uint inv0 = _inventory();
        uint octBefore = IERC20L(oct).balanceOf(alice);
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (uint debt1,) = _vault(alice);
        // only the 9 OCT of mint fee above the minimum is repaid; the rest of the inventory goes to the owner
        assertApproxEqAbs(debt1, MIN_NET_DEBT_PLUS_GAS, uint(1));
        assertApproxEqAbs(IERC20L(oct).balanceOf(alice), octBefore + inv0 - (debt0 - debt1), uint(1));
        assertEq(_inventory(), 0);
    }

    // --- keepers ---

    function test_keeperNeedsTheCadenceAndYieldCoveringTheInterest() public {
        _open(alice, 10 ether, 5000e18);
        _rate(RATE0 * 101 / 100);
        // a regular vault: a keeper takes the protocol's share alone (15% of the yield); nothing is sold
        (uint debt0, uint coll0) = _vault(alice); uint inv0 = _inventory(); uint pot0 = _pot();
        vm.prank(keeper); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (uint debt1, uint coll1) = _vault(alice);
        uint yield = uint(10 ether) - uint(10 ether) * 100 / 101;         // 0.099 wstETH
        assertApproxEqAbs(coll0 - coll1, yield * 15 / 100, 1e9, "the share left the vault");
        assertEq(debt1, debt0, "nothing repaid"); assertEq(_inventory(), inv0, "nothing sold");
        uint collCut = IMockWst(wst).balanceOf(keeper);
        assertEq(collCut, (coll0 - coll1) / 10, "the caller keeps 10% of the share");
        assertEq(_pot(), pot0 + (coll0 - coll1) - collCut, "the rest of the share is in the pot");
        assertEq(IERC20L(oct).balanceOf(keeper), 0);
        // the other 85% is the owner's: the baseline moved up, nothing more to take
        vm.prank(keeper); vm.expectRevert(bytes("no yield yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // auto-repay on: keepers wait for the cadence
        vm.prank(alice); IBOAuto(bo).setAutoRepay(1);                   // monthly
        vm.prank(keeper); vm.expectRevert(bytes("not due yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        vm.warp(block.timestamp + 30 days);
        // a month of interest on ~5,235 OCT is ~6.5 OCT; a 0.05% rate move since the share buys ~9 OCT: enough
        _rate(RATE0 * 101 / 100 * 10005 / 10000);
        vm.prank(keeper); IBOAuto(bo).skimYield(alice, address(0), address(0));
        uint cut = IERC20L(oct).balanceOf(keeper);
        assertGt(cut, 0); assertLt(cut, 0.1e18);                         // 1% of ~9 OCT
        assertEq(IMockWst(wst).balanceOf(keeper), collCut, "a sale pays the keeper in OCT, not wstETH");
        // once per period
        vm.prank(keeper); vm.expectRevert(bytes("not due yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // a month later with too little yield: refused, the yield stays in the vault
        vm.warp(block.timestamp + 30 days);
        _rate(RATE0 * 101 / 100 * 10006 / 10000);                        // +0.01% since the last skim: ~2 OCT
        vm.prank(keeper); vm.expectRevert(bytes("yield below interest"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // the owner is never refused on cadence or size
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
    }

    function test_autoRepayVaultsShareTenPercent() public {
        _open(alice, 10 ether, 5000e18);
        vm.prank(alice); IBOAuto(bo).setAutoRepay(3);
        _rate(RATE0 * 104 / 100);                                        // +4%
        (uint debt0, uint coll0) = _vault(alice); uint inv0 = _inventory(); uint pot0 = _pot();
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (uint debt1, uint coll1) = _vault(alice);
        // 0.3846 wstETH of yield: 10% is the protocol's share, 90% (0.3462 wstETH) buys 692.3 / 1.005 = 688.9 OCT
        assertApproxEqRel(coll0 - coll1, 0.3846e18, 1e15);
        assertApproxEqRel(inv0 - _inventory(), 688.9e18, 1e15);
        assertApproxEqAbs(debt0 - debt1, inv0 - _inventory(), 1e6);
        assertEq(_pot(), pot0 + (coll0 - coll1));
        assertEq(IBOAuto(bo).SHARE_AUTO_BPS(), 1000); assertEq(IBOAuto(bo).SHARE_BPS(), 1500);
    }

    function test_aSaleCappedByTheInventoryTakesTheShareOfWhatItSold() public {
        _open(alice, 100 ether, 5000e18);
        _rate(RATE0 * 110 / 100);                                        // +10%: ~9.09 wstETH of yield, far more than the inventory buys
        (, uint coll0) = _vault(alice); uint inv0 = _inventory(); uint pot0 = _pot(); uint base0 = _baseline(alice);
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        (, uint coll1) = _vault(alice);
        assertEq(_inventory(), 0, "the whole inventory was sold");
        uint collIn = inv0 * 1005 / 1000 * 1e18 / _price();              // what the OCT cost at the offer
        // the share is 15/85 of the collateral sold, so the protocol's part of the yield consumed is 15%
        assertApproxEqAbs(coll0 - coll1, collIn + collIn * 15 / 85, 10, "sale plus share");
        assertEq(_pot(), pot0 + (coll0 - coll1));
        assertEq(_baseline(alice), base0, "the baseline waits: the unsold yield stays skimmable");
        assertGt(coll1 - base0 * 1e18 / (RATE0 * 110 / 100), 8 ether, "most of the yield is still there");
    }

    function test_theShareNeverPushesTheSystemIntoRecoveryMode() public {
        vm.prank(carol); IBuffer(buffer).fill(100 ether);               // room under the debt ceiling
        _open(alice, 1000 ether, 1_000_000e18);
        IPriceT(pf).setPrice(1511e18);                                   // TCR: 1200 * 1511 / 1,206,400 = 150.3%
        assertGe(ITM(tm).getTCR(_price()), 1.5e18); assertLt(ITM(tm).getTCR(_price()), 1.504e18);
        _rate(RATE0 * 110 / 100);                                        // 90.9 wstETH of yield; the share alone would be 13.6
        vm.prank(keeper); vm.expectRevert(bytes("system ratio under 150%"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // the owner's sale removes debt with the collateral and lifts the ratio: allowed
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
        assertGt(ITM(tm).getTCR(_price()), 1.503e18);
    }

    function test_keeperCutIsOnePercentCappedAtFiveOct() public {
        _open(alice, 100 ether, 5000e18);
        vm.prank(alice); IBOAuto(bo).setAutoRepay(3);                   // yearly
        vm.warp(block.timestamp + 365 days);
        _rate(RATE0 * 104 / 100);                                        // ~3.85 wstETH = ~$7,692 of yield, but 500 OCT of inventory
        // top the inventory up so the sale is ~1,000 OCT and the cut would be 10 OCT uncapped
        _open(carol, 100 ether, 100000e18);                              // +500 OCT of mint fee
        vm.prank(keeper); IBOAuto(bo).skimYield(alice, address(0), address(0));
        assertEq(IERC20L(oct).balanceOf(keeper), IBOAuto(bo).SKIM_CUT_CAP());
    }

    // --- guards ---

    function test_noInventoryNoSkim() public {
        _open(alice, 10 ether, 5000e18);
        _takeFromBuffer(dave, _inventory());
        _rate(RATE0 * 102 / 100);
        vm.prank(alice); vm.expectRevert(bytes("no inventory"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
    }

    function test_degradedOracleAndRecoveryModeBlockTheSkim() public {
        _open(alice, 10 ether, 5000e18);
        _rate(RATE0 * 102 / 100);
        IPriceT(pf).setReduceOnly(true);
        vm.prank(alice); vm.expectRevert(bytes("oracle degraded: reduce-only"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        IPriceT(pf).setReduceOnly(false);
        IPriceT(pf).setPrice(700e18);                                     // TCR below 150%
        vm.prank(alice); vm.expectRevert(bytes("not in Recovery Mode"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
    }

    function test_closingTheVaultClearsAutoRepay() public {
        _open(alice, 10 ether, 5000e18);
        vm.prank(alice); IBOAuto(bo).setAutoRepay(2);
        (uint8 c,, uint b) = IBOAuto(bo).autoRepay(alice);
        assertEq(c, 2); assertGt(b, 0);
        vm.prank(bob); IERC20L(oct).transfer(alice, 300e18);           // for the fee and interest
        vm.prank(alice); IBO(bo).closeTrove();
        (c,, b) = IBOAuto(bo).autoRepay(alice);
        assertEq(c, 0); assertEq(b, 0);
        vm.prank(alice); vm.expectRevert(bytes("cadence 0-3"));
        IBOAuto(bo).setAutoRepay(4);
    }
}
