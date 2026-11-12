// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// Minimal ABI surface of the 0.6.11 contracts, used from 0.8 tests via deployCode.
interface ITM {
    function setAddresses(address,address,address,address,address,address,address,address,address,address,address) external;
    function getEntireDebtAndColl(address) external view returns (uint debt, uint coll, uint pDebt, uint pColl);
    function getTroveDebt(address) external view returns (uint);
    function getTroveColl(address) external view returns (uint);
    function getTroveNormalizedDebt(address) external view returns (uint);
    function getPendingLUSDDebtReward(address) external view returns (uint);
    function currentRateIndex() external view returns (uint);
    function rateIndex() external view returns (uint);
    function accrueInterest() external;
    function liquidate(address) external;
    function redeemCollateral(uint,address,address,address,uint,uint,uint) external;
    function getTroveStatus(address) external view returns (uint);
    function getEntireSystemDebt() external view returns (uint);
    function getEntireSystemColl() external view returns (uint);
    function getCurrentICR(address, uint) external view returns (uint);
    function getRedemptionRateWithDecay() external view returns (uint);
    function getRedemptionRate() external view returns (uint);
    function baseRate() external view returns (uint);
    function getBorrowingRate() external view returns (uint);
    function deploymentStartTime() external view returns (uint);
    function getTroveOwnersCount() external view returns (uint);
}
interface IBO {
    function setAddresses(address,address,address,address,address,address,address,address,address,address,address,address) external;
    function openTrove(uint,uint,address,address,uint) external;
    function closeTrove() external;
    function repayLUSD(uint,address,address) external;
    function withdrawLUSD(uint,uint,address,address) external;
    function withdrawColl(uint,address,address) external;
    function addColl(address,address,uint) external;
    function adjustTrove(uint,uint,uint,bool,address,address,uint) external;
    function addCollateralFor(address,address,address,uint) external;
    function claimCollateral() external;
}
interface ISP {
    function setAddresses(address,address,address,address,address,address,address,address,address) external;
    function provideToSP(uint) external;
    function withdrawFromSP(uint) external;
    function withdrawETHGainToTrove(address,address) external;
    function getTotalLUSDDeposits() external view returns (uint);
    function getCompoundedLUSDDeposit(address) external view returns (uint);
    function getDepositorETHGain(address) external view returns (uint);
    function getETH() external view returns (uint);
}
interface IPoolV { function setAddresses(address,address,address,address,address,address) external; function getLUSDDebt() external view returns (uint); function getNormalizedDebt() external view returns (uint); function getETH() external view returns (uint); }
interface IDP { function setAddresses(address,address,address) external; function getLUSDDebt() external view returns (uint); function getETH() external view returns (uint); }
interface ICSP { function setAddresses(address,address,address,address) external; function getCollateral(address) external view returns (uint); }
interface ISorted { function setParams(uint,address,address) external; function getLast() external view returns (address); function getSize() external view returns (uint); }
interface IHintH { function setAddresses(address,address) external; function getRedemptionHints(uint,uint,uint) external view returns (address,uint,uint); }
interface IPriceT { function setPrice(uint) external returns (bool); function getPrice() external view returns (uint); function setReduceOnly(bool) external; function isReduceOnly() external view returns (bool); }
interface IMockWst { function mint(address,uint) external; function approve(address,uint) external returns (bool); function balanceOf(address) external view returns (uint); function setStEthPerToken(uint) external; function stEthPerToken() external view returns (uint); function transfer(address,uint) external returns (bool); }
interface IERC20L { function balanceOf(address) external view returns (uint); function totalSupply() external view returns (uint); function transfer(address,uint) external returns (bool); function approve(address,uint) external returns (bool); }
interface IBuffer {
    function setAddresses(address,address,address,address,address,address,address) external;
    function pot() external view returns (uint);
    function ownPot() external view returns (uint);
    function totalDeposits() external view returns (uint);
    function depositOf(address) external view returns (uint);
    function lockedUntil(address) external view returns (uint);
    function pointsOf(address) external view returns (uint);
    function releasable(uint) external view returns (uint);
    function deposit(uint) external;
    function withdraw(uint) external;
    function checkpoint(address) external;
    function inventory() external view returns (uint);
    function potValue(uint) external view returns (uint);
    function circulatingSupply() external view returns (uint);
    function target() external view returns (uint);
    function redeemCapacity(uint) external view returns (uint);
    function debtCeiling(uint) external view returns (uint);
    function quoteInventory(uint,uint) external view returns (uint);
    function buyInventory(uint,uint) external returns (uint);
    function fill(uint) external;
    function releaseSurplus() external returns (uint);
    function surplusSink() external view returns (address);
    function lastRelease() external view returns (uint);
    function feesOf(address) external view returns (uint);
    function depositorsShareBps() external view returns (uint);
    function feesOwed() external view returns (uint);
    function totalFeesShared() external view returns (uint);
    function claimFees() external returns (uint);
    function transferDepositForSuccession(address, address, uint) external;
}
interface IRegistry {
    function setAddresses(address,address,address,address,address,address,address) external;
    function setPlan(address[] calldata, uint16[] calldata, address) external;
    function clearPlan() external;
    function proveLife() external;
    function getHeirs(address) external view returns (address[] memory, uint16[] memory);
    function getFallbackHeir(address) external view returns (address);
    function lastProof(address) external view returns (uint);
    function hasPlan(address) external view returns (bool);
    function successionState(address) external view returns (uint8, uint, uint);
    function escrowOf(address,address) external view returns (uint);
    function estateOf(address) external view returns (uint,uint,bool);
    function execute(address) external;
    function claimEscrow(address) external;
    function PROOF_PERIOD() external view returns (uint);
    function RETURN_WINDOW() external view returns (uint);
}

/// Deploys the whole LegacyStack system (Phase 1 layout) with the testnet price feed.
contract LegacyStackBase is Test {
    address tm; address bo; address sp; address ap; address dp; address csp; address gas; address st; address hh; address pf; address oct;
    address issuance; address wst; address buffer; address registry;
    address alice = address(0xA11CE); address bob = address(0xB0B); address carol = address(0xCA201); address dave = address(0xDA4E);
    address surplusSink = address(0x5111);
    uint constant YEAR = 365 days;
    uint constant GAS_COMP = 200e18;

    function _bootstrapPeriod() internal virtual pure returns (uint) { return 0; }

    function setUp() public virtual {
        tm  = deployCode("TroveManager.sol:TroveManager", abi.encode(_bootstrapPeriod()));
        bo  = deployCode("BorrowerOperations.sol:BorrowerOperations");
        sp  = deployCode("StabilityPool.sol:StabilityPool");
        ap  = deployCode("ActivePool.sol:ActivePool");
        dp  = deployCode("DefaultPool.sol:DefaultPool");
        csp = deployCode("CollSurplusPool.sol:CollSurplusPool");
        gas = deployCode("GasPool.sol:GasPool");
        st  = deployCode("SortedTroves.sol:SortedTroves");
        hh  = deployCode("HintHelpers.sol:HintHelpers");
        pf  = deployCode("test/upstream-mocks/PriceFeedTestnet.sol:PriceFeedTestnet");
        issuance = deployCode("src/testnet/IssuanceStub.sol:IssuanceStub");
        oct = deployCode("LUSDToken.sol:LUSDToken", abi.encode(tm, sp, bo));
        wst = deployCode("src/testnet/MockWstETH.sol:MockWstETH");
        buffer = deployCode("RedemptionBuffer.sol:RedemptionBuffer");
        registry = deployCode("SuccessionRegistry.sol:SuccessionRegistry", abi.encode(uint(10), uint(0.02 ether)));

        ISorted(st).setParams(1_000_000, tm, bo);
        ITM(tm).setAddresses(bo, ap, dp, sp, gas, csp, pf, oct, st, buffer, registry);
        IBO(bo).setAddresses(tm, ap, dp, sp, gas, csp, pf, st, oct, buffer, wst, registry);
        ISP(sp).setAddresses(bo, tm, ap, oct, st, pf, issuance, wst, registry);
        IPoolV(ap).setAddresses(bo, tm, sp, dp, csp, wst);
        IDP(dp).setAddresses(tm, ap, wst);
        ICSP(csp).setAddresses(bo, tm, ap, wst);
        IHintH(hh).setAddresses(st, tm);
        IBuffer(buffer).setAddresses(tm, bo, pf, oct, wst, surplusSink, registry);
        IRegistry(registry).setAddresses(bo, tm, sp, csp, oct, wst, buffer);
        IPriceT(pf).setPrice(2000e18);

        address[4] memory us = [alice, bob, carol, dave];
        for (uint i = 0; i < 4; i++) {
            IMockWst(wst).mint(us[i], 1000 ether);
            vm.prank(us[i]); IMockWst(wst).approve(bo, type(uint).max);
            vm.prank(us[i]); IMockWst(wst).approve(buffer, type(uint).max);
        }
    }

    // --- helpers ---

    function _open(address who, uint coll, uint amount) internal {
        vm.prank(who); IBO(bo).openTrove(1e18, amount, address(0), address(0), coll);
    }

    function _price() internal view returns (uint) { return IPriceT(pf).getPrice(); }

    // supply must always cover the system debt; the gap is rounding dust only
    function _assertSupplyCoversDebt() internal {
        ITM(tm).accrueInterest();
        uint supply = IERC20L(oct).totalSupply();
        uint debt = ITM(tm).getEntireSystemDebt();
        assertGe(supply, debt, "supply < debt");
        assertLe(supply - debt, 1e9, "dust too large");
    }

    // the OCT inventory and the wstETH pot of the buffer
    function _inventory() internal view returns (uint) { return IERC20L(oct).balanceOf(buffer); }
    function _pot() internal view returns (uint) { return IMockWst(wst).balanceOf(buffer); }

    // move OCT out of the buffer in tests (the buffer itself has no such function)
    function _takeFromBuffer(address to, uint amount) internal {
        vm.prank(buffer); IERC20L(oct).transfer(to, amount);
    }

    function _redeem(address who, uint amount) internal {
        (address first, uint hintNICR,) = IHintH(hh).getRedemptionHints(amount, _price(), 0);
        vm.prank(who);
        ITM(tm).redeemCollateral(amount, first, address(0), address(0), hintNICR, 0, 1e18);
    }
}
