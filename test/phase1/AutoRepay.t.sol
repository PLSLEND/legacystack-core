// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IBOAuto {
    function setAutoRepay(uint8) external;
    function skimYield(address, address, address) external;
    function autoRepay(address) external view returns (uint8 cadence, uint64 lastSkim, uint baseline);
    function SKIM_CUT_CAP() external view returns (uint);
}

/// Auto-repay from staking rewards (LS_06 #160, #161): the yield above the baseline is sold to the reserve's
/// standing offer and the OCT repays the vault. Owner any time without a cut; keepers on the cadence, only
/// when the yield covers the period's interest, for 1% capped at 5 OCT.
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
        // 10 - 10/1.04 = 0.3846 wstETH at $2,000 buys 769.2 / 1.005 = 765.4 OCT, all repaid
        assertApproxEqRel(collSold, 0.3846e18, 1e15);
        assertApproxEqRel(octBought, 765.4e18, 1e15);
        assertApproxEqAbs(debt0 - debt1, octBought, 1e6);
        assertEq(_pot(), pot0 + collSold);                                // the wstETH stays in the reserve
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
        vm.prank(keeper); vm.expectRevert(bytes("auto-repay off"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        vm.prank(alice); IBOAuto(bo).setAutoRepay(1);                   // monthly
        vm.prank(keeper); vm.expectRevert(bytes("not due yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        vm.warp(block.timestamp + 30 days);
        // a month of interest on ~5,235 OCT is ~6.5 OCT; a 0.05% rate move buys ~10 OCT: enough
        _rate(RATE0 * 10005 / 10000);
        vm.prank(keeper); IBOAuto(bo).skimYield(alice, address(0), address(0));
        uint cut = IERC20L(oct).balanceOf(keeper);
        assertGt(cut, 0); assertLt(cut, 0.11e18);                        // 1% of ~10 OCT
        // once per period
        vm.prank(keeper); vm.expectRevert(bytes("not due yet"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // a month later with too little yield: refused, the yield stays in the vault
        vm.warp(block.timestamp + 30 days);
        _rate(RATE0 * 10006 / 10000);                                    // +0.01% since the last skim: ~2 OCT
        vm.prank(keeper); vm.expectRevert(bytes("yield below interest"));
        IBOAuto(bo).skimYield(alice, address(0), address(0));
        // the owner is never refused on cadence or size
        vm.prank(alice); IBOAuto(bo).skimYield(alice, address(0), address(0));
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
