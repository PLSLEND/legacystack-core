// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

/*
* LegacyStack testnet deployment (Sepolia or a local Anvil chain). UNAUDITED. Testnet only.
*
* What it deploys: the whole core (TroveManager, BorrowerOperations, StabilityPool, pools, SortedTroves,
* HintHelpers, MultiTroveGetter, OCT), the LegacyStack contracts (PriceFeed, RedemptionBuffer,
* SuccessionRegistry), a testnet wstETH with a faucet, and the issuance stub. Then it wires every
* setAddresses (each contract renounces ownership inside), opens a small seed vault from the deployer and
* parks 1 OCT in the Stability Pool so the pool never sits at zero and the "last vault" rule never bites a
* user. Finally it writes deployments/<chainId>.json for the frontend.
*
* Environment:
*   ETH_USD_AGGREGATOR  Chainlink ETH/USD proxy. Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306.
*                       Unset: a MockAggregator at $3,000 is deployed (local chains).
*   FEED_TIMEOUT        seconds before a round counts as stale (default 48 h on testnets; 4 h on mainnet).
*   SURPLUS_SINK        where buffer surplus releases go (default: the deployer).
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
interface IDeployBuffer { function setAddresses(address,address,address,address) external; }
interface IDeployRegistry { function setAddresses(address,address,address,address,address,address) external; }
interface IDeployAgg { function setDecimals(uint8) external; function setPrice(int) external; function setPrevPrice(int) external; function setUpdateTime(uint) external; function setPrevUpdateTime(uint) external; function setLatestRoundId(uint80) external; function setPrevRoundId(uint80) external; }
interface IDeployWst { function mint(address,uint) external; function approve(address,uint) external returns (bool); }

contract Deploy is Script {
    struct Addrs {
        address tm; address bo; address sp; address ap; address dp; address csp; address gas; address st; address hh; address mtg;
        address oct; address wst; address feed; address buffer; address registry; address issuance; address agg;
    }

    function run() external {
        address deployer = msg.sender;
        address sink = vm.envOr("SURPLUS_SINK", deployer);
        uint timeout = vm.envOr("FEED_TIMEOUT", uint(48 hours));
        address aggregator = vm.envOr("ETH_USD_AGGREGATOR", address(0));

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
        a.feed = _deployArgs("PriceFeed.sol:PriceFeed", abi.encode(aggregator, a.wst, timeout));
        a.buffer = _deployArgs("RedemptionBuffer.sol:RedemptionBuffer", abi.encode(sink));
        a.registry = _deployArgs("SuccessionRegistry.sol:SuccessionRegistry", abi.encode(uint(10), uint(0.02 ether))); // 0.1% reward, cap 0.02 wstETH
        a.mtg = _deployArgs("MultiTroveGetter.sol:MultiTroveGetter", abi.encode(a.tm, a.st));

        IDeploySorted(a.st).setParams(1_000_000, a.tm, a.bo);
        IDeployTM(a.tm).setAddresses(a.bo, a.ap, a.dp, a.sp, a.gas, a.csp, a.feed, a.oct, a.st, a.buffer, a.registry);
        IDeployBO(a.bo).setAddresses(a.tm, a.ap, a.dp, a.sp, a.gas, a.csp, a.feed, a.st, a.oct, a.buffer, a.wst, a.registry);
        IDeploySP(a.sp).setAddresses(a.bo, a.tm, a.ap, a.oct, a.st, a.feed, a.issuance, a.wst, a.registry);
        IDeployAP(a.ap).setAddresses(a.bo, a.tm, a.sp, a.dp, a.csp, a.wst);
        IDeployDP(a.dp).setAddresses(a.tm, a.ap, a.wst);
        IDeployCSP(a.csp).setAddresses(a.bo, a.tm, a.ap, a.wst);
        IDeployHint(a.hh).setAddresses(a.st, a.tm);
        IDeployBuffer(a.buffer).setAddresses(a.tm, a.feed, a.oct, a.wst);
        IDeployRegistry(a.registry).setAddresses(a.bo, a.tm, a.sp, a.csp, a.oct, a.wst);

        // Seed: a deployer vault and 1 OCT in the Stability Pool (the pool's permanent minimum).
        IDeployWst(a.wst).mint(deployer, 20 ether);
        IDeployWst(a.wst).approve(a.bo, type(uint).max);
        IDeployBO(a.bo).openTrove(1e18, 2000e18, address(0), address(0), 10 ether);
        IDeploySP(a.sp).provideToSP(1e18);

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
        string memory out = vm.serializeAddress(json, "surplusSink", sink);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console.log("Deployment written to", path);
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
