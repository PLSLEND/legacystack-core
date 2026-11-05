// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IAgg {
    function setDecimals(uint8) external;
    function setPrice(int) external;
    function setPrevPrice(int) external;
    function setUpdateTime(uint) external;
    function setPrevUpdateTime(uint) external;
    function setLatestRevert() external;
    function setPrevRevert() external;
    function setDecimalsRevert() external;
    function setLatestRoundId(uint80) external;
    function setPrevRoundId(uint80) external;
}
interface IFeed {
    function fetchPrice() external returns (uint);
    function isReduceOnly() external view returns (bool);
    function lastGoodPrice() external view returns (uint);
    function lastGoodRate() external view returns (uint);
    function peek() external view returns (uint, bool);
    function status() external view returns (uint8);
    function TIMEOUT() external view returns (uint);
}

/// The real feed: Chainlink ETH/USD x Lido stEthPerToken, breakers, reduce-only state, self-healing.
contract PriceFeedTest is LegacyStackBase {
    address agg; address feed;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        agg = deployCode("src/testnet/MockAggregator.sol:MockAggregator");
        IAgg(agg).setDecimals(8);
        IAgg(agg).setPrice(2000e8);
        IAgg(agg).setPrevPrice(1990e8);
        IAgg(agg).setUpdateTime(block.timestamp);
        IAgg(agg).setPrevUpdateTime(block.timestamp - 1 hours);
        IAgg(agg).setLatestRoundId(100);
        IAgg(agg).setPrevRoundId(99);
        feed = deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, wst, uint(4 hours)));
    }

    // Re-deploy the whole system on the real feed (the base used the testnet feed)
    function _wireRealFeed() internal {
        tm  = deployCode("TroveManager.sol:TroveManager", abi.encode(uint(0)));
        bo  = deployCode("BorrowerOperations.sol:BorrowerOperations");
        sp  = deployCode("StabilityPool.sol:StabilityPool");
        ap  = deployCode("ActivePool.sol:ActivePool");
        dp  = deployCode("DefaultPool.sol:DefaultPool");
        csp = deployCode("CollSurplusPool.sol:CollSurplusPool");
        gas = deployCode("GasPool.sol:GasPool");
        st  = deployCode("SortedTroves.sol:SortedTroves");
        hh  = deployCode("HintHelpers.sol:HintHelpers");
        oct = deployCode("LUSDToken.sol:LUSDToken", abi.encode(tm, sp, bo));
        buffer = deployCode("RedemptionBuffer.sol:RedemptionBuffer", abi.encode(surplusSink));
        registry = deployCode("SuccessionRegistry.sol:SuccessionRegistry", abi.encode(uint(10), uint(0.02 ether)));
        ISorted(st).setParams(1_000_000, tm, bo);
        ITM(tm).setAddresses(bo, ap, dp, sp, gas, csp, feed, oct, st, buffer, registry);
        IBO(bo).setAddresses(tm, ap, dp, sp, gas, csp, feed, st, oct, buffer, wst, registry);
        ISP(sp).setAddresses(bo, tm, ap, oct, st, feed, issuance, wst, registry);
        IPoolV(ap).setAddresses(bo, tm, sp, dp, csp, wst);
        IDP(dp).setAddresses(tm, ap, wst);
        ICSP(csp).setAddresses(bo, tm, ap, wst);
        IHintH(hh).setAddresses(st, tm);
        IBuffer(buffer).setAddresses(tm, feed, oct, wst);
        IRegistry(registry).setAddresses(bo, tm, sp, csp, oct, wst);
        address[3] memory us = [alice, bob, carol];
        for (uint i = 0; i < 3; i++) { vm.prank(us[i]); IMockWst(wst).approve(bo, type(uint).max); vm.prank(us[i]); IMockWst(wst).approve(buffer, type(uint).max); }
    }

    function test_priceIsChainlinkTimesLidoRate() public {
        // 2000 USD/ETH x 1.2 stETH per wstETH = 2400 USD per wstETH
        assertEq(IFeed(feed).lastGoodPrice(), 2400e18);
        assertEq(IFeed(feed).fetchPrice(), 2400e18);
        assertFalse(IFeed(feed).isReduceOnly());
        IMockWst(wst).setStEthPerToken(1.201e18);
        IAgg(agg).setPrice(2100e8);
        IAgg(agg).setPrevPrice(2000e8);
        assertEq(IFeed(feed).fetchPrice(), 2100e18 * 1.201e18 / 1e18);
    }

    function test_scalesAnyDecimals() public {
        IAgg(agg).setDecimals(18);
        IAgg(agg).setPrice(2000e18);
        IAgg(agg).setPrevPrice(1990e18);
        assertEq(IFeed(feed).fetchPrice(), 2400e18);
        IAgg(agg).setDecimals(6);
        IAgg(agg).setPrice(2000e6);
        IAgg(agg).setPrevPrice(1990e6);
        assertEq(IFeed(feed).fetchPrice(), 2400e18);
    }

    function test_staleRoundDegradesAndFreshRoundHeals() public {
        vm.warp(block.timestamp + 4 hours + 1);
        IAgg(agg).setPrice(1500e8); // the market moved while the feed was frozen
        assertEq(IFeed(feed).fetchPrice(), 2400e18); // last good price, not the stale answer
        assertTrue(IFeed(feed).isReduceOnly());
        (uint p, bool healthy) = IFeed(feed).peek();
        assertEq(p, 2400e18); assertFalse(healthy);
        // a fresh round heals without anyone's permission
        IAgg(agg).setUpdateTime(block.timestamp);
        IAgg(agg).setPrevPrice(1510e8);
        assertEq(IFeed(feed).fetchPrice(), 1500e18 * 12 / 10);
        assertFalse(IFeed(feed).isReduceOnly());
    }

    function test_brokenAnswersDegrade() public {
        IAgg(agg).setPrice(0);
        IFeed(feed).fetchPrice(); assertTrue(IFeed(feed).isReduceOnly());
        IAgg(agg).setPrice(-1);
        IFeed(feed).fetchPrice(); assertTrue(IFeed(feed).isReduceOnly());
        IAgg(agg).setPrice(2000e8);
        IFeed(feed).fetchPrice(); assertFalse(IFeed(feed).isReduceOnly());
        IAgg(agg).setLatestRevert();
        IFeed(feed).fetchPrice(); assertTrue(IFeed(feed).isReduceOnly());
    }

    function test_fiftyPercentRoundJumpDegrades() public {
        IAgg(agg).setPrice(900e8); // -55% against the previous round of 1990
        IFeed(feed).fetchPrice();
        assertTrue(IFeed(feed).isReduceOnly());
        assertEq(IFeed(feed).lastGoodPrice(), 2400e18);
        IAgg(agg).setPrevPrice(1000e8); // the next round confirms the level: heals
        IFeed(feed).fetchPrice();
        assertFalse(IFeed(feed).isReduceOnly());
    }

    function test_lidoRateJumpDegradesThenHealsWithTime() public {
        IMockWst(wst).setStEthPerToken(1.25e18); // +4.2% in one step: impossible for Lido, so the feed refuses it
        IFeed(feed).fetchPrice();
        assertTrue(IFeed(feed).isReduceOnly());
        assertEq(IFeed(feed).lastGoodRate(), 1.2e18);
        // the band widens 0.1% per day: after 33 days a 4.2% move is inside 1% + 3.3%
        vm.warp(block.timestamp + 33 days);
        IAgg(agg).setUpdateTime(block.timestamp);
        IFeed(feed).fetchPrice();
        assertFalse(IFeed(feed).isReduceOnly());
        assertEq(IFeed(feed).lastGoodRate(), 1.25e18);
    }

    function test_lidoCallFailureDegrades() public {
        IMockWst(wst).setStEthPerToken(0);
        IFeed(feed).fetchPrice();
        assertTrue(IFeed(feed).isReduceOnly());
    }

    function test_reduceOnlyBlocksNewRiskButKeepsTheExits() public {
        _wireRealFeed();
        _open(bob, 50 ether, 20000e18);
        _open(alice, 10 ether, 5000e18);
        vm.prank(bob); ISP(sp).provideToSP(10000e18);
        vm.prank(carol); IBuffer(buffer).fill(5 ether);
        // freeze the oracle
        vm.warp(block.timestamp + 5 hours);
        IFeed(feed).fetchPrice();
        assertTrue(IFeed(feed).isReduceOnly());

        // blocked: open, borrow, withdraw collateral, redeem, buy inventory
        vm.prank(carol); vm.expectRevert(bytes("BorrowerOps: Oracle degraded, only repay, add collateral and close are open"));
        IBO(bo).openTrove(1e18, 3000e18, address(0), address(0), 5 ether);
        vm.prank(alice); vm.expectRevert(bytes("BorrowerOps: Oracle degraded, only repay, add collateral and close are open"));
        IBO(bo).withdrawLUSD(1e18, 100e18, address(0), address(0));
        vm.prank(alice); vm.expectRevert(bytes("BorrowerOps: Oracle degraded, only repay, add collateral and close are open"));
        IBO(bo).withdrawColl(1 ether, address(0), address(0));
        vm.prank(bob); vm.expectRevert(bytes("TM: oracle degraded"));
        ITM(tm).redeemCollateral(5000e18, address(0), address(0), address(0), 0, 0, 1e18);
        vm.prank(carol); vm.expectRevert(bytes("RedemptionBuffer: oracle degraded, offer closed"));
        IBuffer(buffer).buyInventory(1e18, 1 ether);

        // open: add collateral, repay, close, Stability Pool withdrawal, liquidation at the last good price
        vm.prank(alice); IBO(bo).addColl(address(0), address(0), 1 ether);
        vm.prank(alice); IBO(bo).repayLUSD(1000e18, address(0), address(0));
        vm.prank(bob); ISP(sp).withdrawFromSP(1000e18);
        vm.prank(bob); IERC20L(oct).transfer(alice, 300e18);
        vm.prank(alice); IBO(bo).closeTrove();
        assertEq(ITM(tm).getTroveStatus(alice), 2);
        _assertSupplyCoversDebt();
    }

    function test_liquidationAtLastGoodPriceWhileDegraded() public {
        _wireRealFeed();
        _open(bob, 50 ether, 20000e18);
        vm.prank(bob); ISP(sp).provideToSP(15000e18);
        _open(alice, 3 ether, 5000e18); // 7200 / 5225 = 138%
        // a fresh round at 1500: alice 5400/5225 = 103% -> liquidatable
        IAgg(agg).setPrice(1500e8); IAgg(agg).setPrevPrice(1510e8);
        IFeed(feed).fetchPrice();
        // then the feed freezes
        vm.warp(block.timestamp + 5 hours);
        IFeed(feed).fetchPrice();
        assertTrue(IFeed(feed).isReduceOnly());
        vm.prank(carol); ITM(tm).liquidate(alice);
        assertEq(ITM(tm).getTroveStatus(alice), 3);
        _assertSupplyCoversDebt();
    }

    function test_deploymentNeedsHealthySources() public {
        IAgg(agg).setPrice(0);
        vm.expectRevert(bytes("PriceFeed: sources must be healthy at deployment"));
        deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, wst, uint(4 hours)));
    }
}
