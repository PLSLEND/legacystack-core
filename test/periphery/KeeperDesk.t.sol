// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IDesk {
    struct Pending { uint price; bool oracleHealthy; bool recoveryMode; address[] liquidatable; address[] executable; address[] skimmable; uint octReward; uint collReward; }
    function run(address[] calldata, address[] calldata, address[] calldata) external returns (uint, uint);
    function pending(uint) external view returns (Pending memory);
    function skimmable(address) external view returns (uint);
}
interface IBOCadence { function setAutoRepay(uint8) external; }

contract KeeperDeskTest is LegacyStackBase {
    address desk;
    address keeper = address(0x4EE9);

    function setUp() public override {
        super.setUp();
        desk = deployCode("src/periphery/KeeperDesk.sol:KeeperDesk", abi.encode(tm, bo, st, pf, buffer, registry, oct, wst));
        // a safe vault, a Stability Pool deposit to absorb liquidations, and a risky vault
        _open(alice, 100 ether, 20_000e18);
        vm.prank(alice); ISP(sp).provideToSP(15_000e18);
        _open(bob, 6 ether, 10_000e18);          // 6 * 2000 / 10200 = 117%
    }

    function test_pendingIsEmptyWhileEverythingIsHealthy() public view {
        IDesk.Pending memory w = IDesk(desk).pending(50);
        assertTrue(w.oracleHealthy);
        assertEq(w.liquidatable.length, 0);
        assertEq(w.executable.length, 0);
        assertEq(w.octReward, 0);
    }

    function test_runLiquidatesAndPaysTheCaller() public {
        IPriceT(pf).setPrice(1800e18);           // bob: 6 * 1800 / 10200 = 105.9% < 110%
        IDesk.Pending memory w = IDesk(desk).pending(50);
        assertEq(w.liquidatable.length, 1);
        assertEq(w.liquidatable[0], bob);
        assertEq(w.octReward, GAS_COMP);
        assertEq(w.collReward, 6 ether / 200);

        address[] memory none;
        vm.prank(keeper);
        (uint octPaid, uint collPaid) = IDesk(desk).run(w.liquidatable, none, none);
        assertEq(octPaid, GAS_COMP, "gas compensation to the caller");
        assertEq(collPaid, 6 ether / 200, "0.5% of the collateral to the caller");
        assertEq(IERC20L(oct).balanceOf(keeper), GAS_COMP);
        assertEq(IMockWst(wst).balanceOf(keeper), 6 ether / 200);
        assertEq(IERC20L(oct).balanceOf(desk), 0, "desk keeps nothing");
        assertEq(IMockWst(wst).balanceOf(desk), 0, "desk keeps nothing");
        assertEq(ITM(tm).getTroveStatus(bob), 3, "closed by liquidation");
    }

    function test_runExecutesADueSuccessionAndPaysTheCaller() public {
        address[] memory heirs = new address[](1); heirs[0] = carol;
        uint16[] memory bps = new uint16[](1); bps[0] = 10000;
        vm.prank(bob); IRegistry(registry).setPlan(heirs, bps, address(0));
        // bob repays, so settlement is simple: the estate pays its debt with the buffer's inventory and the pool
        vm.warp(block.timestamp + YEAR + 30 days + 1);

        IDesk.Pending memory w = IDesk(desk).pending(50);
        assertEq(w.executable.length, 1);
        assertEq(w.executable[0], bob);
        assertEq(w.liquidatable.length, 0);

        address[] memory none;
        uint before = IMockWst(wst).balanceOf(keeper);
        vm.prank(keeper);
        (, uint collPaid) = IDesk(desk).run(none, w.executable, none);
        assertGt(collPaid, 0, "executor reward paid");
        assertLe(collPaid, 0.02 ether, "reward capped");
        assertEq(IMockWst(wst).balanceOf(keeper) - before, collPaid);
        assertEq(ITM(tm).getTroveStatus(bob), 5, "closed by succession");
        assertGt(IMockWst(wst).balanceOf(carol), 0, "heir received collateral");
    }

    function test_runNeverRevertsOnNothingToDo() public {
        address[] memory bogus = new address[](1); bogus[0] = alice;   // healthy vault: nothing to liquidate
        address[] memory alive = new address[](1); alive[0] = alice;   // no plan: nothing to execute
        address[] memory none;
        vm.prank(keeper);
        (uint octPaid, uint collPaid) = IDesk(desk).run(bogus, alive, none);
        assertEq(octPaid, 0); assertEq(collPaid, 0);
        assertEq(ITM(tm).getTroveStatus(alice), 1, "alice untouched");
    }

    function test_pendingReportsDueSkimsAndRunCollectsTheCut() public {
        vm.prank(alice); IBOCadence(bo).setAutoRepay(2);              // quarterly
        IDesk.Pending memory w = IDesk(desk).pending(50);
        assertEq(w.skimmable.length, 0);                                // nothing due yet
        vm.warp(block.timestamp + 91 days);
        IMockWst(wst).setStEthPerToken(1.2e18 * 101 / 100);             // +1%: ~0.99 wstETH of yield on 100
        assertGt(IDesk(desk).skimmable(alice), 0.98e18);
        w = IDesk(desk).pending(50);
        assertEq(w.skimmable.length, 1);
        assertEq(w.skimmable[0], alice);
        assertGt(w.octReward, 0);
        address[] memory none;
        (uint octPaid,) = IDesk(desk).run(none, none, w.skimmable);
        assertGe(octPaid, w.octReward);                                 // the run accrues 91 days of interest into the inventory first
        assertEq(IERC20L(oct).balanceOf(address(this)), octPaid);
        assertEq(IDesk(desk).pending(50).skimmable.length, 0);          // done for this quarter
    }
}
