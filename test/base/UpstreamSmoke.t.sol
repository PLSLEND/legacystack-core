// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LegacyStackBase.sol";

contract UpstreamSmokeTest is LegacyStackBase {
    function _bootstrapPeriod() internal override pure returns (uint) { return 14 days; }

    function test_openBorrowRepayClose() public {
        vm.prank(alice);
        IBO(bo).openTrove(1e18, 5000e18, address(0), address(0), 10 ether);
        (uint debt, uint coll,,) = ITM(tm).getEntireDebtAndColl(alice);
        assertEq(coll, 10 ether);
        // debt = 5000 + 200 gas comp + 0.5% fee on 5000 = 5225
        assertEq(debt, 5225e18);
        assertEq(IERC20L(oct).balanceOf(alice), 5000e18);
        assertEq(IERC20L(oct).totalSupply(), IPoolV(ap).getLUSDDebt());
        // need extra OCT to close (fee + gas comp is handled by the gas pool) -> bob opens and sends alice 25
        vm.prank(bob);
        IBO(bo).openTrove(1e18, 5000e18, address(0), address(0), 10 ether);
        vm.prank(bob); IERC20L(oct).transfer(alice, 25e18);
        vm.prank(alice); IBO(bo).closeTrove();
        assertEq(ITM(tm).getTroveStatus(alice), 2); // closedByOwner
        assertEq(IERC20L(oct).totalSupply(), IPoolV(ap).getLUSDDebt());
    }

    function test_liquidationViaStabilityPool() public {
        vm.prank(bob);   IBO(bo).openTrove(1e18, 20000e18, address(0), address(0), 50 ether);
        vm.prank(alice); IBO(bo).openTrove(1e18, 4000e18, address(0), address(0), 3 ether); // ICR 6000/4220 = 142%
        vm.prank(bob);   ISP(sp).provideToSP(15000e18, address(0));
        IPriceT(pf).setPrice(1500e18); // alice ICR = 4500/4225 = 106.5% < 110%
        uint icr = ITM(tm).getCurrentICR(alice, 1500e18);
        assertLt(icr, 1.1e18);
        vm.prank(carol); ITM(tm).liquidate(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 3); // closedByLiquidation
        assertEq(IERC20L(oct).totalSupply(), IPoolV(ap).getLUSDDebt());
    }

    function test_redemption() public {
        vm.prank(alice); IBO(bo).openTrove(1e18, 4000e18, address(0), address(0), 4 ether); // lowest ICR
        vm.prank(bob);   IBO(bo).openTrove(1e18, 20000e18, address(0), address(0), 50 ether);
        vm.warp(block.timestamp + 15 days); // past bootstrap period
        uint price = IPriceT(pf).getPrice();
        (address first, uint hintNICR,) = IHintH(hh).getRedemptionHints(5000e18, price, 0);
        uint ethBefore = IMockWst(wst).balanceOf(bob);
        vm.prank(bob);
        ITM(tm).redeemCollateral(5000e18, first, address(0), address(0), hintNICR, 0, 1e18);
        assertGt(IMockWst(wst).balanceOf(bob), ethBefore);
        // 5,000 OCT redeemed: alice (lowest ICR) is fully redeemed and closed, the rest comes from bob
        assertEq(ITM(tm).getTroveStatus(alice), 4); // closedByRedemption
        assertGe(IERC20L(oct).totalSupply(), IPoolV(ap).getLUSDDebt());
        assertLe(IERC20L(oct).totalSupply() - IPoolV(ap).getLUSDDebt(), 1e9);
    }
}
