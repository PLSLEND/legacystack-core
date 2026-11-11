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
interface IBufferOffer { function offerPrice() external returns (uint); }
interface IChron { function set(uint, uint) external; function setDead(bool) external; }
interface IBOSettleT { function settleForSuccession(address, uint) external returns (uint, bool, uint); }
interface IFeed {
    function fetchPrice() external returns (uint);
    function isReduceOnly() external view returns (bool);
    function isWindDown() external view returns (bool);
    function lowerOfMarket(uint) external view returns (uint);
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
        feed = deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, address(0), address(0), wst, uint(4 hours)));
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
        buffer = deployCode("RedemptionBuffer.sol:RedemptionBuffer");
        registry = deployCode("SuccessionRegistry.sol:SuccessionRegistry", abi.encode(uint(10), uint(0.02 ether)));
        ISorted(st).setParams(1_000_000, tm, bo);
        ITM(tm).setAddresses(bo, ap, dp, sp, gas, csp, feed, oct, st, buffer, registry);
        IBO(bo).setAddresses(tm, ap, dp, sp, gas, csp, feed, st, oct, buffer, wst, registry);
        ISP(sp).setAddresses(bo, tm, ap, oct, st, feed, issuance, wst, registry);
        IPoolV(ap).setAddresses(bo, tm, sp, dp, csp, wst);
        IDP(dp).setAddresses(tm, ap, wst);
        ICSP(csp).setAddresses(bo, tm, ap, wst);
        IHintH(hh).setAddresses(st, tm);
        IBuffer(buffer).setAddresses(tm, bo, feed, oct, wst, surplusSink);
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
        vm.prank(carol); vm.expectRevert(bytes("oracle degraded: reduce-only"));
        IBO(bo).openTrove(1e18, 3000e18, address(0), address(0), 5 ether);
        vm.prank(alice); vm.expectRevert(bytes("oracle degraded: reduce-only"));
        IBO(bo).withdrawLUSD(1e18, 100e18, address(0), address(0));
        vm.prank(alice); vm.expectRevert(bytes("oracle degraded: reduce-only"));
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
        deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, address(0), address(0), wst, uint(4 hours)));
    }

    // --- two ETH/USD networks (#160) ---

    function _twoSourceFeed() internal returns (address chr, address f) {
        chr = deployCode("src/testnet/MockChronicle.sol:MockChronicle", abi.encode(uint(2000e18)));
        f = deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, chr, address(0), wst, uint(4 hours)));
    }

    function test_twoSourcesMeanSurvivorAndDisagreement() public {
        (address chr, address f) = _twoSourceFeed();
        assertEq(IFeed(f).fetchPrice(), 2400e18);                         // both at 2,000
        IChron(chr).set(2020e18, block.timestamp);                         // 1% apart: the mean, 2,010 x 1.2
        assertEq(IFeed(f).fetchPrice(), 2010e18 * 12 / 10);
        assertFalse(IFeed(f).isReduceOnly());
        IChron(chr).set(2100e18, block.timestamp);                         // 5% apart: degraded, last good price
        assertEq(IFeed(f).fetchPrice(), 2010e18 * 12 / 10);
        assertTrue(IFeed(f).isReduceOnly());
        IChron(chr).setDead(true);                                         // Chronicle dead: Chainlink alone, healthy
        assertEq(IFeed(f).fetchPrice(), 2400e18);
        assertFalse(IFeed(f).isReduceOnly());
        IChron(chr).setDead(false);
        IChron(chr).set(2000e18, block.timestamp);
        IAgg(agg).setLatestRevert();                                       // Chainlink dead: Chronicle alone
        assertEq(IFeed(f).fetchPrice(), 2400e18);
        assertFalse(IFeed(f).isReduceOnly());
        vm.warp(block.timestamp + 4 hours + 1);                            // Chronicle stale too: degraded
        IFeed(f).fetchPrice();
        assertTrue(IFeed(f).isReduceOnly());
        assertFalse(IFeed(f).isWindDown());
    }

    function test_windDownIsPermanentAndSettlesWithAHaircut() public {
        (address chr, address f) = _twoSourceFeed();
        feed = f; _wireRealFeed();
        _open(bob, 100 ether, 50_000e18);                                  // inventory and pool capital for the settlement
        vm.prank(bob); ISP(sp).provideToSP(20_000e18);
        _open(alice, 10 ether, 5000e18);
        address[] memory a = new address[](1); uint16[] memory b = new uint16[](1); a[0] = carol; b[0] = 10000;
        vm.prank(alice); IRegistry(registry).setPlan(a, b, address(0));
        // both networks die; 29 days later it is still only degraded
        IChron(chr).setDead(true); IAgg(agg).setLatestRevert();
        vm.warp(block.timestamp + 29 days);
        IFeed(f).fetchPrice();
        assertTrue(IFeed(f).isReduceOnly()); assertFalse(IFeed(f).isWindDown());
        // 30 days: the end state, permanent even if a source comes back
        vm.warp(block.timestamp + 1 days + 1);
        IFeed(f).fetchPrice();
        assertTrue(IFeed(f).isWindDown());
        IAgg(agg).setUpdateTime(block.timestamp);                           // Chainlink is back: too late for this deployment
        assertEq(IFeed(f).fetchPrice(), 2400e18);
        assertTrue(IFeed(f).isWindDown()); assertTrue(IFeed(f).isReduceOnly());
        // no new borrowing ever again; repay and add collateral stay open
        vm.prank(alice); vm.expectRevert(bytes("oracle degraded: reduce-only"));
        IBO(bo).withdrawLUSD(1e18, 100e18, address(0), address(0));
        vm.prank(alice); IBO(bo).addColl(address(0), address(0), 1 ether);
        // succession settles at the stale price with a 20% haircut: the reserve gets more wstETH per OCT than at par
        vm.warp(block.timestamp + 365 days + 30 days + 1);
        ITM(tm).accrueInterest();                                           // so the inventory does not move inside execute
        uint pot0 = _pot(); uint inv0 = _inventory();
        (uint8 st,,) = IRegistry(registry).successionState(alice); assertEq(st, 3);
        IRegistry(registry).execute(alice);
        uint octUsed = inv0 - _inventory();
        uint collIn = _pot() - pot0;
        assertApproxEqRel(collIn, octUsed * 1e18 / (2400e18 * 80 / 100), 1e12);
        assertEq(ITM(tm).getTroveStatus(alice), 5);
        assertGt(IMockWst(wst).balanceOf(carol), 0);
    }

    // --- direction-aware market price (#162) ---

    function test_lowerOfMarketOnlyWhereTheProtocolPays() public {
        address mkt = deployCode("src/testnet/MockAggregator.sol:MockAggregator");
        IAgg(mkt).setDecimals(8); IAgg(mkt).setPrice(1900e8); IAgg(mkt).setPrevPrice(1900e8);
        IAgg(mkt).setUpdateTime(block.timestamp); IAgg(mkt).setPrevUpdateTime(block.timestamp - 1 hours);
        IAgg(mkt).setLatestRoundId(10); IAgg(mkt).setPrevRoundId(9);
        feed = deployCode("PriceFeed.sol:PriceFeed", abi.encode(agg, address(0), mkt, wst, uint(4 hours)));
        // canonical 2,400; market 1,900 x 1.2 = 2,280 (stETH at a 5% discount)
        assertEq(IFeed(feed).fetchPrice(), 2400e18);
        assertEq(IFeed(feed).lowerOfMarket(2400e18), 2280e18);
        IAgg(mkt).setPrice(2100e8); IAgg(mkt).setPrevPrice(2100e8);        // market above canonical: canonical wins
        assertEq(IFeed(feed).lowerOfMarket(2400e18), 2400e18);
        vm.warp(block.timestamp + 5 hours);                                 // stale market feed: ignored
        IAgg(mkt).setPrice(1000e8); IAgg(mkt).setPrevPrice(1000e8);
        assertEq(IFeed(feed).lowerOfMarket(2400e18), 2400e18);
        IAgg(agg).setUpdateTime(block.timestamp); IAgg(mkt).setUpdateTime(block.timestamp);
        IAgg(mkt).setPrice(1900e8); IAgg(mkt).setPrevPrice(1900e8);
        _wireRealFeed();
        _open(bob, 100 ether, 20_000e18);                                   // a safe vault so the system ratio is not the binding check
        // a borrow is checked at 2,280: 10 wstETH back at most 20,727 OCT of debt at 110%; 20,700 x 1.005 + 200 = 21,003 passes at 2,400 (114%) but not at 2,280 (108.6%)
        vm.prank(alice); vm.expectRevert(bytes("ratio would fall under 110%"));
        IBO(bo).openTrove(1e18, 20_700e18, address(0), address(0), 10 ether);
        _open(alice, 10 ether, 20_000e18);                                  // 20,000 x 1.005 + 200 = 20,300 < 20,727
        // the standing offer values wstETH at the lower price too: more wstETH per OCT than at the canonical price
        assertEq(IBufferOffer(buffer).offerPrice(), 2280e18);
        assertGt(IBuffer(buffer).quoteInventory(1000e18, 2280e18), IBuffer(buffer).quoteInventory(1000e18, 2400e18));
        // everything else reads the canonical price
        assertEq(IFeed(feed).fetchPrice(), 2400e18);
        assertEq(ITM(tm).getCurrentICR(alice, IFeed(feed).fetchPrice()), uint(10 ether) * 2400e18 / 20_300e18);
    }
}
