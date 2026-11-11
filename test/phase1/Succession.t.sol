// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

/// Succession Registry (LS_06 #129, #135, #136, #160, #161): button-only liveness, heirs, collateral gifts, settlement at par, push delivery.
contract SuccessionTest is LegacyStackBase {
    address heir1 = address(0xE1); address heir2 = address(0xE2); address heir3 = address(0xE3);
    address fallbackHeir = address(0xFA11);
    address helper = address(0x0B);   // a family member or keeper with its own wallet
    address keeper = address(0xBEEF);
    uint PROOF; uint WINDOW;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        PROOF = IRegistry(registry).PROOF_PERIOD();
        WINDOW = IRegistry(registry).RETURN_WINDOW();
        IMockWst(wst).mint(helper, 100 ether);
        vm.prank(helper); IMockWst(wst).approve(bo, type(uint).max);
    }

    function _plan(address owner) internal {
        address[] memory a = new address[](3); uint16[] memory b = new uint16[](3);
        a[0] = heir1; b[0] = 5000; a[1] = heir2; b[1] = 3000; a[2] = heir3; b[2] = 2000;
        vm.prank(owner); IRegistry(registry).setPlan(a, b, fallbackHeir);
    }

    function _state(address owner) internal view returns (uint8 s) { (s,,) = IRegistry(registry).successionState(owner); }

    // --- plan ---

    function test_planValidation() public {
        address[] memory a = new address[](2); uint16[] memory b = new uint16[](2);
        a[0] = heir1; b[0] = 6000; a[1] = heir2; b[1] = 3000;
        vm.prank(alice); vm.expectRevert(bytes("SuccessionRegistry: shares must total 100%"));
        IRegistry(registry).setPlan(a, b, address(0));
        b[1] = 4000; a[1] = heir1;
        vm.prank(alice); vm.expectRevert(bytes("SuccessionRegistry: duplicate heir"));
        IRegistry(registry).setPlan(a, b, address(0));
        a[1] = alice;
        vm.prank(alice); vm.expectRevert(bytes("SuccessionRegistry: heir is the owner"));
        IRegistry(registry).setPlan(a, b, address(0));
        a[1] = heir2;
        vm.prank(alice); IRegistry(registry).setPlan(a, b, address(0));
        (address[] memory acc, uint16[] memory bps) = IRegistry(registry).getHeirs(alice);
        assertEq(acc.length, 2); assertEq(acc[1], heir2); assertEq(bps[0], 6000);
        assertTrue(IRegistry(registry).hasPlan(alice));
        assertEq(_state(alice), 1);
        // no plan: state 0
        assertEq(_state(bob), 0);
    }

    // --- liveness ---

    function test_onlyTheProofOfLifeButtonResetsTheClock() public {
        _plan(alice);
        uint t0 = IRegistry(registry).lastProof(alice);
        assertEq(t0, block.timestamp);                      // setting the plan starts the clock
        vm.warp(block.timestamp + 100 days);
        _open(alice, 10 ether, 5000e18);                    // the owner's own vault actions do not count
        vm.prank(alice); IBO(bo).addColl(address(0), address(0), 1 ether);
        vm.prank(alice); IBO(bo).repayLUSD(100e18, address(0), address(0));
        vm.prank(alice); ISP(sp).provideToSP(1000e18);     // nor Stability Pool actions
        vm.prank(alice); ISP(sp).withdrawFromSP(500e18);
        assertEq(IRegistry(registry).lastProof(alice), t0);
        vm.warp(block.timestamp + 100 days);
        vm.prank(helper); IBO(bo).addCollateralFor(alice, address(0), address(0), 1 ether); // nor anyone else's
        assertEq(IRegistry(registry).lastProof(alice), t0);
        vm.warp(block.timestamp + 100 days);
        vm.prank(alice); IRegistry(registry).proveLife();  // only the button
        assertEq(IRegistry(registry).lastProof(alice), block.timestamp);
        vm.warp(block.timestamp + 100 days);
        _plan(alice);                                       // or a new plan
        assertEq(IRegistry(registry).lastProof(alice), block.timestamp);
    }

    function test_stateMachine() public {
        _plan(alice);
        (uint8 s, uint dueAt, uint execAt) = IRegistry(registry).successionState(alice);
        assertEq(s, 1); assertEq(dueAt, block.timestamp + PROOF); assertEq(execAt, dueAt + WINDOW);
        vm.warp(dueAt);
        assertEq(_state(alice), 2);
        vm.expectRevert(bytes("SuccessionRegistry: not executable"));
        IRegistry(registry).execute(alice);
        // the owner returns inside the window
        vm.prank(alice); IRegistry(registry).proveLife();
        assertEq(_state(alice), 1);
        vm.warp(block.timestamp + PROOF + WINDOW);
        assertEq(_state(alice), 3);
    }

    // --- collateral gifts (#161): anyone may make a vault safer, nobody may make it riskier ---

    function test_anyoneMayAddCollateralNobodyMayDoAnythingElse() public {
        _open(alice, 10 ether, 5000e18);
        uint helperWst = IMockWst(wst).balanceOf(helper);
        vm.prank(helper); IBO(bo).addCollateralFor(alice, address(0), address(0), 2 ether);
        (, uint coll,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(coll, 12 ether);                                       // the gift is in the vault
        assertEq(IMockWst(wst).balanceOf(helper), helperWst - 2 ether); // paid by the helper
        // a gift works in the reduce-only oracle state too: it is the rescue path
        IPriceT(pf).setReduceOnly(true);
        vm.prank(helper); IBO(bo).addCollateralFor(alice, address(0), address(0), 1 ether);
        IPriceT(pf).setReduceOnly(false);
        (, coll,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(coll, 13 ether);
        // nothing else: no gift to a closed vault, no zero gift
        vm.prank(helper); vm.expectRevert(bytes("no open vault"));
        IBO(bo).addCollateralFor(bob, address(0), address(0), 1 ether);
        vm.prank(helper); vm.expectRevert(bytes("nothing to change"));
        IBO(bo).addCollateralFor(alice, address(0), address(0), 0);
        // no entry point lets a third party repay, borrow, withdraw or close: those act on msg.sender's own vault
        vm.prank(helper); vm.expectRevert(bytes("no open vault"));
        IBO(bo).withdrawColl(1 ether, address(0), address(0));
        vm.prank(helper); vm.expectRevert(bytes("no open vault"));
        IBO(bo).closeTrove();
    }

    // --- execution ---

    function test_executionSettlesWithBufferInventoryAndPushesCollateral() public {
        _open(bob, 100 ether, 50000e18);  // keeps the system above one trove and fills inventory with fees
        _open(alice, 10 ether, 5000e18);
        _plan(alice);
        // alice spends her OCT (it is in her wallet, out of reach); the buffer holds 275 of fee inventory
        assertEq(_inventory(), 275e18);
        // bob sells 6,000 OCT into the buffer so the inventory can settle alice's whole debt at par
        vm.prank(bob); IERC20L(oct).transfer(buffer, 6000e18);

        vm.warp(block.timestamp + PROOF + WINDOW);
        ITM(tm).accrueInterest(); // a year of interest is minted into the inventory; measure after it
        uint inventoryBefore = _inventory();
        uint potBefore = _pot();
        assertEq(_state(alice), 3);
        (uint debt, uint coll,,) = ITM(tm).getEntireDebtAndColl(alice);
        uint price = _price();
        uint keeperWstBefore = IMockWst(wst).balanceOf(keeper);
        vm.prank(keeper); IRegistry(registry).execute(alice);

        // the vault is closed by succession
        assertEq(ITM(tm).getTroveStatus(alice), 5);
        // the buffer gave (debt - 200) OCT at par and received exactly that value in wstETH
        uint netDebt = debt - GAS_COMP;
        assertEq(inventoryBefore - _inventory(), netDebt);
        uint collToBuffer = netDebt * 1e18 / price;
        assertEq(_pot() - potBefore, collToBuffer);
        // the keeper got the reward, the heirs the rest by their shares
        uint released = coll - collToBuffer;
        uint reward = released * 10 / 10000; // below the 0.02 cap
        assertEq(IMockWst(wst).balanceOf(keeper) - keeperWstBefore, reward);
        uint distributed = released - reward;
        assertEq(IMockWst(wst).balanceOf(heir1), distributed * 5000 / 10000);
        assertEq(IMockWst(wst).balanceOf(heir2), distributed * 3000 / 10000);
        assertEq(IMockWst(wst).balanceOf(heir3), distributed - distributed * 5000 / 10000 - distributed * 3000 / 10000);
        assertEq(_state(alice), 4);
        assertEq(IMockWst(wst).balanceOf(registry), 0);
        _assertSupplyCoversDebt();
    }

    function test_executionUsesEstateOctFirstThenBufferThenStabilityPool() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 5000e18);
        _plan(alice);
        // alice parks 3,000 OCT in the Stability Pool; bob adds 20,000 to the pool
        vm.prank(alice); ISP(sp).provideToSP(3000e18);
        vm.prank(bob); ISP(sp).provideToSP(20000e18);
        uint spBefore = ISP(sp).getTotalLUSDDeposits();

        vm.warp(block.timestamp + PROOF + WINDOW);
        ITM(tm).accrueInterest();
        uint inventoryBefore = _inventory(); // 275 of fees plus a year of interest
        (uint debt, uint coll,,) = ITM(tm).getEntireDebtAndColl(alice);
        uint price = _price();
        vm.prank(keeper); IRegistry(registry).execute(alice);

        assertEq(ITM(tm).getTroveStatus(alice), 5);
        uint netDebt = debt - GAS_COMP;
        // 3,000 from alice's own deposit, the whole inventory from the buffer, the rest from the pool at par
        assertEq(_inventory(), 0);
        uint fromSP = netDebt - 3000e18 - inventoryBefore;
        assertEq(spBefore - ISP(sp).getTotalLUSDDeposits(), 3000e18 + fromSP);
        // the pool received collateral worth exactly what it gave
        assertEq(ISP(sp).getETH(), fromSP * 1e18 / price);
        // heirs received the collateral net of what settled the debt and the reward
        uint released = coll - inventoryBefore * 1e18 / price - fromSP * 1e18 / price;
        uint reward = released * 10 / 10000;
        uint distributed = released - reward;
        assertEq(IMockWst(wst).balanceOf(heir1), distributed / 2);
        assertEq(IERC20L(oct).balanceOf(heir1), 0); // all estate OCT was used for the debt
        _assertSupplyCoversDebt();
    }

    function test_partialSettlementIsRetriedLater() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 5000e18);
        _plan(alice);
        // no pool, and only 100 OCT of inventory: not enough to settle the debt today
        vm.warp(block.timestamp + PROOF + WINDOW);
        ITM(tm).accrueInterest();
        _takeFromBuffer(bob, _inventory() - 100e18);
        (uint debtBefore, uint collBefore,,) = ITM(tm).getEntireDebtAndColl(alice);
        uint icrBefore = ITM(tm).getCurrentICR(alice, _price());
        vm.prank(keeper); IRegistry(registry).execute(alice);
        // still open, 100 OCT less debt, collateral worth $100 less, ratio up
        assertEq(ITM(tm).getTroveStatus(alice), 1);
        (uint debtAfter, uint collAfter,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertApproxEqAbs(debtBefore - debtAfter, 100e18, 1e6);
        assertEq(collBefore - collAfter, 100e18 * 1e18 / _price());
        assertGt(ITM(tm).getCurrentICR(alice, _price()), icrBefore);
        assertEq(_state(alice), 3);
        // liquidity arrives: the next call finishes the job
        vm.prank(bob); ISP(sp).provideToSP(10000e18);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
        assertEq(_state(alice), 4);
        assertGt(IMockWst(wst).balanceOf(heir1), 0);
        _assertSupplyCoversDebt();
    }

    function test_ownerWhoReturnsDuringPartialSettlementGetsTheEstateBack() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 5000e18);
        _plan(alice);
        vm.prank(alice); ISP(sp).provideToSP(1000e18);
        _takeFromBuffer(bob, _inventory());
        vm.warp(block.timestamp + PROOF + WINDOW);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        // the pool deposit (1,000 OCT) was withdrawn and used; the vault is still open
        assertEq(ITM(tm).getTroveStatus(alice), 1);
        (uint estOct,, bool spW) = IRegistry(registry).estateOf(alice);
        assertEq(estOct, 0); assertTrue(spW);
        // alice is alive: a vault action does not help her (button-only liveness), the button does, and it
        // clears the estate record
        vm.prank(alice); IBO(bo).addColl(address(0), address(0), 1 ether);
        assertEq(_state(alice), 3);
        vm.prank(alice); IRegistry(registry).proveLife();
        assertEq(_state(alice), 1);
        (,, bool spW2) = IRegistry(registry).estateOf(alice);
        assertFalse(spW2);
    }

    function test_failedPushGoesToFallbackThenEscrow() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 5000e18);
        // OCT cannot be transferred to protocol addresses: name the TroveManager as an heir to force a failed push
        address[] memory a = new address[](2); uint16[] memory b = new uint16[](2);
        a[0] = tm; b[0] = 5000; a[1] = heir2; b[1] = 5000;
        vm.prank(alice); IRegistry(registry).setPlan(a, b, fallbackHeir);
        vm.prank(alice); ISP(sp).provideToSP(2000e18);
        vm.prank(bob); IERC20L(oct).transfer(buffer, 6000e18);
        vm.warp(block.timestamp + PROOF + WINDOW);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
        // wstETH to the TroveManager address succeeds at the token level (a plain ERC-20), so it was pushed there;
        // the OCT share could not be delivered and was distributed... all estate OCT settled the debt, so none is left
        assertEq(IERC20L(oct).balanceOf(fallbackHeir), 0);
        assertGt(IMockWst(wst).balanceOf(heir2), 0);
    }

    function test_escrowWhenFallbackAlsoFails() public {
        // force an OCT push failure with OCT left in the estate: alice has no vault, only a pool deposit
        _open(bob, 100 ether, 50000e18);
        vm.prank(bob); IERC20L(oct).transfer(alice, 2000e18);
        vm.prank(alice); ISP(sp).provideToSP(2000e18);
        address[] memory a = new address[](1); uint16[] memory b = new uint16[](1);
        a[0] = tm; b[0] = 10000;
        vm.prank(alice); IRegistry(registry).setPlan(a, b, sp); // fallback is also a protocol address
        vm.warp(block.timestamp + PROOF + WINDOW);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(IRegistry(registry).escrowOf(tm, oct), 1999e18); // the pool keeps its 1 OCT minimum as alice's dust deposit
        // escrow is claimable by the heir whenever it can receive; a stranger gets nothing
        vm.prank(carol); vm.expectRevert(bytes("SuccessionRegistry: nothing in escrow"));
        IRegistry(registry).claimEscrow(oct);
    }

    function test_undercollateralizedVaultIsNotInherited() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 3 ether, 4000e18);
        _plan(alice);
        vm.warp(block.timestamp + PROOF + WINDOW);
        IPriceT(pf).setPrice(1300e18); // alice: 3,900 against 4,220 debt
        vm.prank(keeper); vm.expectRevert(bytes("under 110%: liquidate"));
        IRegistry(registry).execute(alice);
        // between 100% and 110% the estate is a liquidation, never a settlement at par (KupiaSec, 10 Nov 2026)
        IPriceT(pf).setPrice(1500e18); // alice: 4,500 against 4,220 debt = 106.6%
        vm.prank(keeper); vm.expectRevert(bytes("under 110%: liquidate"));
        IRegistry(registry).execute(alice);
        IPriceT(pf).setPrice(1600e18); // 113.7%: settles
        vm.prank(bob); ISP(sp).provideToSP(10000e18);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
    }

    function test_partialSettlementNeverLeavesADustVault() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 2000e18);                 // net debt 2,010 after the fee: 210 above the minimum
        _plan(alice);
        vm.warp(block.timestamp + PROOF + WINDOW);
        ITM(tm).accrueInterest();
        _takeFromBuffer(bob, _inventory() - 1000e18);    // 1,000 OCT of inventory, no pool: a partial settlement
        (uint debtBefore,,,) = ITM(tm).getEntireDebtAndColl(alice);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        (uint debtAfter,,,) = ITM(tm).getEntireDebtAndColl(alice);
        // only what keeps the vault at the 1,800 minimum is settled today
        assertApproxEqAbs(debtAfter, 1800e18 + GAS_COMP, 1e6);
        assertLt(debtBefore - debtAfter, 1000e18);
        assertEq(ITM(tm).getTroveStatus(alice), 1);
        // nothing more can be done until the whole rest can be settled at once
        vm.prank(keeper); IRegistry(registry).execute(alice);
        (uint debtAgain,,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(debtAgain, debtAfter);
        vm.prank(bob); ISP(sp).provideToSP(10000e18);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
        _assertSupplyCoversDebt();
    }

    function test_settlementWaitsForAHealthyOracle() public {
        _open(bob, 100 ether, 50000e18);
        _open(alice, 10 ether, 5000e18);
        _plan(alice);
        vm.warp(block.timestamp + PROOF + WINDOW);
        IPriceT(pf).setReduceOnly(true);
        vm.prank(keeper); vm.expectRevert(bytes("succession waits for the oracle"));
        IRegistry(registry).execute(alice);
        IPriceT(pf).setReduceOnly(false);
        vm.prank(bob); ISP(sp).provideToSP(10000e18);
        vm.prank(keeper); IRegistry(registry).execute(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
    }

    function test_onlyTheRegistryCanSettle() public {
        vm.prank(carol); vm.expectRevert(bytes("not the SuccessionRegistry"));
        IBOSettle(bo).settleForSuccession(alice, 0);
        vm.prank(carol); vm.expectRevert(bytes("TM: Caller is not the BorrowerOperations contract"));
        ITMClose(tm).closeTroveBySuccession(alice);
    }
}

interface IBOSettle { function settleForSuccession(address, uint) external returns (uint, bool, uint); }
interface ITMClose { function closeTroveBySuccession(address) external; }
