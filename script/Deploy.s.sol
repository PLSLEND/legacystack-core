// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

/*
* LegacyStack testnet deployment (Sepolia or a local Anvil chain). UNAUDITED. Testnet only.
*
* What it deploys: the whole core (TroveManager, BorrowerOperations, StabilityPool, pools, SortedTroves,
* HintHelpers, MultiTroveGetter, OCT), the LegacyStack contracts (PriceFeed, RedemptionBuffer,
* SuccessionRegistry), the periphery (Keeper desk, burn auction, surplus splitter, POL keeper, reserve
* rewards), a testnet wstETH, STACK and USDe with faucets, and the issuance stub. Then it wires every
* setAddresses (each contract renounces ownership inside), opens a small seed vault from the deployer, parks
* 1 OCT in the Stability Pool so the pool never sits at zero and the "last vault" rule never bites a user,
* seeds the OCT/USDe pool and the reserve rewards. Finally it writes deployments/<chainId>.json.
*
* Environment:
*   ETH_USD_AGGREGATOR  Chainlink ETH/USD proxy. Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306.
*                       Unset: a MockAggregator at $3,000 is deployed (local chains).
*   FEED_TIMEOUT        seconds before a round counts as stale (default 48 h on testnets; 4 h on mainnet).
*   CHRONICLE_ETH_USD   Chronicle ETH/USD oracle (mainnet: the feed must be admitted via SelfKisser first).
*                       Unset: a MockChronicle seeded at the aggregator's price is deployed (testnets).
*   STETH_USD_AGGREGATOR Chainlink stETH/USD market feed for the direction-aware price (mainnet
*                       0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8). Unset: canonical only (no Sepolia feed).
*   UNISWAP_NPM         Uniswap v3 NonfungiblePositionManager. Sepolia: 0x1238536071E1c677A632429e3655c799b22cDA52.
*                       When set, a testnet USDe is deployed, an OCT/USDe 0.05% pool is created at 1:1 with
*                       20,000 OCT + 20,000 USDe of protocol-seeded liquidity in the 0.98-1.02 band, and the
*                       POL keeper (Uniswap v3 flavour) is deployed against it. Unset: the splitter sends both
*                       halves to the burn auction.
*
* Run: forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $PK  (or --account)
*/
interface IDeployTM { function setAddresses(address,address,address,address,address,address,address,address,address,address,address) external; }
interface IDeployBO { function setAddresses(address,address,address,address,address,address,address,address,address,address,address,address) external; function openTrove(uint,uint,address,address,uint) external; }
interface IDeploySP { function setAddresses(address,address,address,address,address,address,address,address,address) external; function provideToSP(uint) external; }
interface IDeployAP { function setAddresses(address,address,address,address,address,address) external; }
interface IDeployDP { function setAddresses(address,address,address) external; }
interface IDeployCSP { function setAddresses(address,address,address,address) external; }
interface IDeploySorted { function setParams(uint,address,address) external; }
interface IDeployHint { function setAddresses(address,address) external; }
interface IDeployBuffer { function setAddresses(address,address,address,address,address,address,address) external; }
interface IDeployRegistry { function setAddresses(address,address,address,address,address,address,address) external; }
interface IDeployAgg { function setDecimals(uint8) external; function setPrice(int) external; function setPrevPrice(int) external; function setUpdateTime(uint) external; function setPrevUpdateTime(uint) external; function setLatestRoundId(uint80) external; function setPrevRoundId(uint80) external; }
interface IDeployWst { function mint(address,uint) external; function approve(address,uint) external returns (bool); function transfer(address,uint) external returns (bool); }
interface IDeployPol { function seed() external returns (uint); }
interface IDeployAggRead { function decimals() external view returns (uint8); function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }
interface IDeployNPM {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external payable returns (address pool);
    function mint(MintParams calldata params) external payable returns (uint tokenId, uint128 liquidity, uint amount0, uint amount1);
}

contract Deploy is Script {
    struct Addrs {
        address tm; address bo; address sp; address ap; address dp; address csp; address gas; address st; address hh; address mtg;
        address oct; address wst; address feed; address buffer; address registry; address issuance; address agg;
        address desk; address usde; address pool; address lpDesk;
        address stack; address auction; address pol; address splitter; address rewards;
    }

    function run() external {
        address deployer = msg.sender;
        uint timeout = vm.envOr("FEED_TIMEOUT", uint(48 hours));
        address aggregator = vm.envOr("ETH_USD_AGGREGATOR", address(0));
        address npm = vm.envOr("UNISWAP_NPM", address(0));

        vm.startBroadcast();
        Addrs memory a;

        if (aggregator == address(0)) {
            a.agg = _deploy("src/testnet/MockAggregator.sol:MockAggregator");
            IDeployAgg(a.agg).setDecimals(8);
            IDeployAgg(a.agg).setPrice(3000e8);
            IDeployAgg(a.agg).setPrevPrice(3000e8);
            IDeployAgg(a.agg).setUpdateTime(block.timestamp);
            IDeployAgg(a.agg).setPrevUpdateTime(block.timestamp - 3600);
            IDeployAgg(a.agg).setLatestRoundId(2);
            IDeployAgg(a.agg).setPrevRoundId(1);
            aggregator = a.agg;
        }

        a.wst = _deploy("src/testnet/MockWstETH.sol:MockWstETH");
        a.tm  = _deployArgs("TroveManager.sol:TroveManager", abi.encode(uint(0)));   // no bootstrap pause on the testnet
        a.bo  = _deploy("BorrowerOperations.sol:BorrowerOperations");
        a.sp  = _deploy("StabilityPool.sol:StabilityPool");
        a.ap  = _deploy("ActivePool.sol:ActivePool");
        a.dp  = _deploy("DefaultPool.sol:DefaultPool");
        a.csp = _deploy("CollSurplusPool.sol:CollSurplusPool");
        a.gas = _deploy("GasPool.sol:GasPool");
        a.st  = _deploy("SortedTroves.sol:SortedTroves");
        a.hh  = _deploy("HintHelpers.sol:HintHelpers");
        a.issuance = _deploy("src/testnet/IssuanceStub.sol:IssuanceStub");
        a.oct = _deployArgs("LUSDToken.sol:LUSDToken", abi.encode(a.tm, a.sp, a.bo));
        address chronicle = vm.envOr("CHRONICLE_ETH_USD", address(0));
        if (chronicle == address(0)) { chronicle = _deployArgs("src/testnet/MockChronicle.sol:MockChronicle", abi.encode(_ethUsd18(aggregator))); }
        address stEthUsd = vm.envOr("STETH_USD_AGGREGATOR", address(0));
        a.feed = _deployArgs("PriceFeed.sol:PriceFeed", abi.encode(aggregator, chronicle, stEthUsd, a.wst, timeout));
        a.buffer = _deploy("RedemptionBuffer.sol:RedemptionBuffer");
        a.registry = _deployArgs("SuccessionRegistry.sol:SuccessionRegistry", abi.encode(uint(10), uint(0.02 ether))); // 0.1% reward, cap 0.02 wstETH
        a.mtg = _deployArgs("MultiTroveGetter.sol:MultiTroveGetter", abi.encode(a.tm, a.st));

        // The market venue (testnet: Uniswap v3), created now so the POL keeper can be built against it
        if (npm != address(0)) {
            a.usde = _deploy("src/testnet/MockUSDe.sol:MockUSDe");
            (address t0, address t1) = a.oct < a.usde ? (a.oct, a.usde) : (a.usde, a.oct);
            a.pool = IDeployNPM(npm).createAndInitializePoolIfNecessary(t0, t1, 500, uint160(1) << 96);
        }

        // STACK sinks and emissions (periphery): burn auction, POL keeper, splitter, reserve rewards
        a.stack = _deploy("src/testnet/MockStack.sol:MockStack");
        a.auction = _deployArgs("src/periphery/BurnAuction.sol:BurnAuction", abi.encode(a.stack, a.wst, uint(0.5 ether), uint(1000e18)));
        a.pol = a.pool != address(0)
            ? _deployArgs("src/periphery/PolKeeperV3.sol:PolKeeperV3", abi.encode(a.wst, a.oct, a.buffer, a.feed, a.pool, npm))
            : a.auction;
        a.splitter = _deployArgs("src/periphery/SurplusSplitter.sol:SurplusSplitter", abi.encode(a.wst, a.auction, a.pol));
        a.rewards = _deployArgs("src/periphery/ReserveRewards.sol:ReserveRewards", abi.encode(a.stack, a.buffer, uint(1e18) / uint(1 days))); // 1 STACK per wstETH per day

        IDeploySorted(a.st).setParams(1_000_000, a.tm, a.bo);
        IDeployTM(a.tm).setAddresses(a.bo, a.ap, a.dp, a.sp, a.gas, a.csp, a.feed, a.oct, a.st, a.buffer, a.registry);
        IDeployBO(a.bo).setAddresses(a.tm, a.ap, a.dp, a.sp, a.gas, a.csp, a.feed, a.st, a.oct, a.buffer, a.wst, a.registry);
        IDeploySP(a.sp).setAddresses(a.bo, a.tm, a.ap, a.oct, a.st, a.feed, a.issuance, a.wst, a.registry);
        IDeployAP(a.ap).setAddresses(a.bo, a.tm, a.sp, a.dp, a.csp, a.wst);
        IDeployDP(a.dp).setAddresses(a.tm, a.ap, a.wst);
        IDeployCSP(a.csp).setAddresses(a.bo, a.tm, a.ap, a.wst);
        IDeployHint(a.hh).setAddresses(a.st, a.tm);
        IDeployBuffer(a.buffer).setAddresses(a.tm, a.bo, a.feed, a.oct, a.wst, a.splitter, a.registry);
        IDeployRegistry(a.registry).setAddresses(a.bo, a.tm, a.sp, a.csp, a.oct, a.wst, a.buffer);
        a.desk = _deployArgs("src/periphery/KeeperDesk.sol:KeeperDesk", abi.encode(a.tm, a.bo, a.st, a.feed, a.buffer, a.registry, a.oct, a.wst));
        // Liquidity through the protocol (#171): OCT/USDe positions held for their owners, inherited with the plan
        if (a.pool != address(0)) {
            a.lpDesk = _deployArgs("src/periphery/LiquidityDesk.sol:LiquidityDesk", abi.encode(a.oct, a.pool, npm, a.registry));
        }

        // Seed: a deployer vault (its OCT seeds the pool below) and 1 OCT in the Stability Pool (the pool's
        // permanent minimum).
        IDeployWst(a.wst).mint(deployer, 60 ether);
        IDeployWst(a.wst).approve(a.bo, type(uint).max);
        IDeployBO(a.bo).openTrove(1e18, 25_000e18, address(0), address(0), 40 ether);
        IDeploySP(a.sp).provideToSP(1e18);

        // Reserve rewards: 1,000,000 test STACK to pay depositors with; 10,000 to the deployer for the auction
        IDeployWst(a.stack).mint(a.rewards, 100_000e18);
        for (uint i = 0; i < 9; i++) { IDeployWst(a.stack).mint(a.rewards, 100_000e18); }
        IDeployWst(a.stack).mint(deployer, 10_000e18);

        // OCT/USDe pool (Uniswap v3, 0.05%), protocol-seeded at par through the POL keeper, which places the
        // seed two-sided (0.98 to 1.02), holds it forever and counts it as the protocol's share (#170), so the
        // peg and the buffer can be tested against a market. Testnet only; the mainnet venue is a Curve
        // StableSwap-NG pool.
        if (npm != address(0)) {
            IDeployWst(a.usde).mint(deployer, 100_000e18);
            IDeployWst(a.oct).transfer(a.pol, 20_000e18);
            IDeployWst(a.usde).transfer(a.pol, 20_000e18);
            IDeployPol(a.pol).seed();
        }

        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "troveManager", a.tm);
        vm.serializeAddress(json, "borrowerOperations", a.bo);
        vm.serializeAddress(json, "stabilityPool", a.sp);
        vm.serializeAddress(json, "activePool", a.ap);
        vm.serializeAddress(json, "defaultPool", a.dp);
        vm.serializeAddress(json, "collSurplusPool", a.csp);
        vm.serializeAddress(json, "gasPool", a.gas);
        vm.serializeAddress(json, "sortedTroves", a.st);
        vm.serializeAddress(json, "hintHelpers", a.hh);
        vm.serializeAddress(json, "multiTroveGetter", a.mtg);
        vm.serializeAddress(json, "oct", a.oct);
        vm.serializeAddress(json, "wstETH", a.wst);
        vm.serializeAddress(json, "priceFeed", a.feed);
        vm.serializeAddress(json, "ethUsdAggregator", aggregator);
        vm.serializeAddress(json, "redemptionBuffer", a.buffer);
        vm.serializeAddress(json, "successionRegistry", a.registry);
        vm.serializeAddress(json, "keeperDesk", a.desk);
        vm.serializeAddress(json, "liquidityDesk", a.lpDesk);
        vm.serializeAddress(json, "usde", a.usde);
        vm.serializeAddress(json, "octUsdePool", a.pool);
        vm.serializeAddress(json, "uniswapPositionManager", npm);
        vm.serializeAddress(json, "stack", a.stack);
        vm.serializeAddress(json, "burnAuction", a.auction);
        vm.serializeAddress(json, "polKeeper", a.pol);
        vm.serializeAddress(json, "reserveRewards", a.rewards);
        string memory out = vm.serializeAddress(json, "surplusSink", a.splitter);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console.log("Deployment written to", path);
    }

    // The aggregator's current answer scaled to 18 decimals (to seed the testnet Chronicle at the same price)
    function _ethUsd18(address agg) internal view returns (uint) {
        (, int256 answer,,,) = IDeployAggRead(agg).latestRoundData();
        uint8 d = IDeployAggRead(agg).decimals();
        require(answer > 0, "aggregator: no answer");
        return d >= 18 ? uint(answer) / (10 ** (d - 18)) : uint(answer) * (10 ** (18 - d));
    }

    function _deploy(string memory what) internal returns (address addr) {
        bytes memory bytecode = vm.getCode(what);
        assembly ("memory-safe") { addr := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(addr != address(0), string.concat("deploy failed: ", what));
    }

    function _deployArgs(string memory what, bytes memory args) internal returns (address addr) {
        bytes memory bytecode = abi.encodePacked(vm.getCode(what), args);
        assembly ("memory-safe") { addr := create(0, add(bytecode, 0x20), mload(bytecode)) }
        require(addr != address(0), string.concat("deploy failed: ", what));
    }
}
