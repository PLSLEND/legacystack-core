// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Keeper desk: one call that does every piece of pending housekeeping and hands every reward the protocol
* already pays to whoever made the call. Periphery: holds no funds between calls, has no owner, changes no
* rule. Anyone may call it; a bot, a wallet, a browser button.
*
* What a run does, in order: accrue interest; liquidate the vaults passed in (the protocol pays 200 OCT plus
* 0.5% of the collateral per vault, Liquity's gas compensation); execute the successions passed in (the
* protocol pays the estate's executor reward) and hand each settled estate's protocol-provided liquidity to
* its heirs through the liquidity desk, so one press moves everything; skim the staking yield of the vaults passed in whose auto-repay
* is due (the protocol pays 1% of the OCT, capped at 5 OCT); and, when `tend` is set, the reserve's
* housekeeping: release the surplus if one is due, split whatever the surplus sink holds, let the POL keeper
* work and harvest its fees (the splitter pays the caller 0.1% of what it splits); then sweep the OCT and collateral this contract
* received to the caller. The caller chooses the categories, so a frequent job such as a liquidation pays only
* for itself (LS_06 #169). Steps that have nothing to do are skipped, never reverted, so a run always finishes.
* `pending()` is the matching read: it scans the riskiest vaults and reports what a run would do, roughly
* what it would pay, and whether the reserve side has anything to tend.
*/
interface IDeskTroveManager {
    function accrueInterest() external;
    function batchLiquidateTroves(address[] calldata troves) external;
    function getCurrentICR(address borrower, uint price) external view returns (uint);
    function getEntireDebtAndColl(address borrower) external view returns (uint debt, uint coll, uint pendingDebt, uint pendingColl);
    function checkRecoveryMode(uint price) external view returns (bool);
    function getTCR(uint price) external view returns (uint);
    function MCR() external view returns (uint);
    function CCR() external view returns (uint);
    function LUSD_GAS_COMPENSATION() external view returns (uint);
    function PERCENT_DIVISOR() external view returns (uint);
    function RATE_PER_YEAR() external view returns (uint);
    function getPendingETHReward(address borrower) external view returns (uint);
    function getTroveStatus(address borrower) external view returns (uint);
}
interface IDeskBorrowerOperations {
    function skimYield(address owner, address upperHint, address lowerHint) external;
    function autoRepay(address owner) external view returns (uint8 cadence, uint64 lastSkim, uint baseline);
    function SKIM_CUT_BPS() external view returns (uint);
    function SKIM_CUT_CAP() external view returns (uint);
}
interface IDeskWstETH { function stEthPerToken() external view returns (uint); }
interface IDeskSortedTroves { function getLast() external view returns (address); function getPrev(address id) external view returns (address); function getSize() external view returns (uint); }
interface IDeskPriceFeed { function peek() external view returns (uint price, bool healthy); }
interface IDeskBuffer {
    function releaseSurplus() external returns (uint); function inventory() external view returns (uint); function OFFER_PREMIUM() external view returns (uint);
    function surplusSink() external view returns (address); function releasable(uint price) external view returns (uint); function lastRelease() external view returns (uint);
}
interface IDeskSplitter { function split() external returns (uint, uint); function polKeeper() external view returns (address); function pending() external view returns (uint); }
interface IDeskPol { function work() external returns (uint); function harvest() external returns (uint); function octAtOrAbovePar() external view returns (bool); }
interface IDeskRegistry {
    function successionState(address owner) external view returns (uint8 state, uint dueAt, uint executableAt);
    function execute(address owner) external;
    function REWARD_BPS() external view returns (uint);
    function REWARD_CAP() external view returns (uint);
}
interface IDeskERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }
interface IDeskLiquidity { function positionOf(address owner) external view returns (uint); function inherit(address owner) external; }

contract KeeperDesk {
    IDeskTroveManager public immutable troveManager;
    IDeskBorrowerOperations public immutable borrowerOperations;
    IDeskSortedTroves public immutable sortedTroves;
    IDeskPriceFeed public immutable priceFeed;
    IDeskBuffer public immutable redemptionBuffer;
    IDeskRegistry public immutable successionRegistry;
    IDeskERC20 public immutable octToken;
    IDeskERC20 public immutable collateralToken;
    address public immutable liquidityDesk;         // zero on a chain without the market pool

    event Run(address indexed caller, uint liquidated, uint executed, uint skimmed, uint surplusReleased, uint octPaid, uint collPaid);

    constructor(address _troveManager, address _borrowerOperations, address _sortedTroves, address _priceFeed, address _buffer, address _registry, address _oct, address _coll, address _liquidityDesk) {
        troveManager = IDeskTroveManager(_troveManager);
        borrowerOperations = IDeskBorrowerOperations(_borrowerOperations);
        sortedTroves = IDeskSortedTroves(_sortedTroves);
        priceFeed = IDeskPriceFeed(_priceFeed);
        redemptionBuffer = IDeskBuffer(_buffer);
        successionRegistry = IDeskRegistry(_registry);
        octToken = IDeskERC20(_oct);
        collateralToken = IDeskERC20(_coll);
        liquidityDesk = _liquidityDesk;
    }

    /// The chosen categories, in one transaction. Rewards go to the caller.
    function run(address[] calldata _liquidate, address[] calldata _execute, address[] calldata _skim, bool _tend) external returns (uint octPaid, uint collPaid) {
        troveManager.accrueInterest();

        uint liquidated;
        if (_liquidate.length > 0) {
            try troveManager.batchLiquidateTroves(_liquidate) { liquidated = _liquidate.length; } catch {}
        }

        uint executed;
        for (uint i = 0; i < _execute.length; i++) {
            try successionRegistry.execute(_execute[i]) { executed++; } catch {}
            // the estate's liquidity provided through the protocol goes to the heirs in the same press
            if (liquidityDesk != address(0)) {
                try IDeskLiquidity(liquidityDesk).positionOf(_execute[i]) returns (uint tokenId) {
                    if (tokenId != 0) { try IDeskLiquidity(liquidityDesk).inherit(_execute[i]) {} catch {} }
                } catch {}
            }
        }

        uint skimmed;
        for (uint i = 0; i < _skim.length; i++) {
            try borrowerOperations.skimYield(_skim[i], address(0), address(0)) { skimmed++; } catch {}
        }

        uint released;
        if (_tend) released = _tend_();

        octPaid = octToken.balanceOf(address(this));
        collPaid = collateralToken.balanceOf(address(this));
        if (octPaid > 0) require(octToken.transfer(msg.sender, octPaid), "KeeperDesk: OCT transfer failed");
        if (collPaid > 0) require(collateralToken.transfer(msg.sender, collPaid), "KeeperDesk: collateral transfer failed");
        emit Run(msg.sender, liquidated, executed, skimmed, released, octPaid, collPaid);
    }

    // The reserve side: release a due surplus, split it, let the POL keeper work and harvest its fees
    // (periphery contracts, any of which may be absent on a chain).
    function _tend_() internal returns (uint released) {
        try redemptionBuffer.releaseSurplus() returns (uint amount) { released = amount; } catch {}
        address sink = redemptionBuffer.surplusSink();
        if (sink.code.length > 0) {
            try IDeskSplitter(sink).split() {} catch {}
            try IDeskSplitter(sink).polKeeper() returns (address pol) {
                if (pol.code.length > 0) {
                    try IDeskPol(pol).work() {} catch {}
                    try IDeskPol(pol).harvest() {} catch {}
                }
            } catch {}
        }
    }

    struct Rewards { uint threshold; uint gasComp; uint divisor; uint rewardBps; uint rewardCap; uint rate; uint ratePerYear; uint premium; uint inventory; uint cutBps; uint cutCap; }
    struct Pending { uint price; bool oracleHealthy; bool recoveryMode; address[] liquidatable; address[] executable; address[] skimmable; uint octReward; uint collReward; bool tend; }

    struct Scan { address owner; address[] liq; address[] exe; address[] skm; uint nl; uint ne; uint ns; }

    /// What a run would do right now. Scans up to `_maxScan` vaults from the riskiest end of the list.
    /// Rewards are estimates at the current price; liquidation needs the Stability Pool or redistribution
    /// to absorb the debt, which the protocol decides at execution time.
    function pending(uint _maxScan) external view returns (Pending memory w) {
        (w.price, w.oracleHealthy) = priceFeed.peek();
        w.recoveryMode = troveManager.checkRecoveryMode(w.price);
        Rewards memory r = Rewards({
            threshold: w.recoveryMode ? troveManager.CCR() : troveManager.MCR(),
            gasComp: troveManager.LUSD_GAS_COMPENSATION(),
            divisor: troveManager.PERCENT_DIVISOR(),
            rewardBps: successionRegistry.REWARD_BPS(),
            rewardCap: successionRegistry.REWARD_CAP(),
            rate: IDeskWstETH(address(collateralToken)).stEthPerToken(),
            ratePerYear: troveManager.RATE_PER_YEAR(),
            premium: redemptionBuffer.OFFER_PREMIUM(),
            inventory: redemptionBuffer.inventory(),
            cutBps: borrowerOperations.SKIM_CUT_BPS(),
            cutCap: borrowerOperations.SKIM_CUT_CAP()
        });

        uint n = sortedTroves.getSize();
        if (n > _maxScan) n = _maxScan;
        Scan memory s = Scan({ owner: sortedTroves.getLast(), liq: new address[](n), exe: new address[](n), skm: new address[](n), nl: 0, ne: 0, ns: 0 });
        for (uint i = 0; i < n && s.owner != address(0); i++) {
            _scanOne(s, w, r);
            s.owner = sortedTroves.getPrev(s.owner);
        }

        w.tend = _tendPending(w.price);
        w.liquidatable = new address[](s.nl);
        w.executable = new address[](s.ne);
        w.skimmable = new address[](s.ns);
        for (uint i = 0; i < s.nl; i++) w.liquidatable[i] = s.liq[i];
        for (uint i = 0; i < s.ne; i++) w.executable[i] = s.exe[i];
        for (uint i = 0; i < s.ns; i++) w.skimmable[i] = s.skm[i];
    }

    // Something for the reserve side to do: a due surplus, an unsplit sink, or a POL keeper with wstETH at par
    function _tendPending(uint _price) internal view returns (bool) {
        try redemptionBuffer.releasable(_price) returns (uint rel) {
            if (rel > 0 && redemptionBuffer.lastRelease() + 1 days <= block.timestamp) return true;
        } catch {}
        address sink = redemptionBuffer.surplusSink();
        if (sink.code.length == 0) return false;
        try IDeskSplitter(sink).pending() returns (uint p) { if (p > 0) return true; } catch {}
        try IDeskSplitter(sink).polKeeper() returns (address pol) {
            if (pol.code.length > 0 && collateralToken.balanceOf(pol) > 0) {
                try IDeskPol(pol).octAtOrAbovePar() returns (bool ok) { return ok; } catch {}
            }
        } catch {}
        return false;
    }

    function _scanOne(Scan memory _s, Pending memory _w, Rewards memory _r) internal view {
        (bool isLiq, bool isExe, uint octAdd, uint collAdd) = _check(_s.owner, _w.price, _r);
        if (isLiq) _s.liq[_s.nl++] = _s.owner;
        if (isExe) _s.exe[_s.ne++] = _s.owner;
        (bool isSkim, uint cut) = _checkSkim(_s.owner, _w.price, _r);
        if (isSkim) { _s.skm[_s.ns++] = _s.owner; octAdd += cut; }
        _w.octReward += octAdd;
        _w.collReward += collAdd;
    }

    function _check(address _owner, uint _price, Rewards memory _r)
        internal
        view
        returns (bool isLiq, bool isExe, uint octAdd, uint collAdd)
    {
        (, uint coll, , ) = troveManager.getEntireDebtAndColl(_owner);
        if (troveManager.getCurrentICR(_owner, _price) < _r.threshold) {
            isLiq = true;
            octAdd = _r.gasComp;
            collAdd = coll / _r.divisor;
        }
        (uint8 state, , ) = successionRegistry.successionState(_owner);
        if (state == 3) {
            isExe = true;
            uint reward = coll * _r.rewardBps / 10000;
            collAdd += reward < _r.rewardCap ? reward : _r.rewardCap;
        }
    }

    /// The staking yield a vault could sell to the reserve right now, in wstETH (0 for a closed vault).
    function skimmable(address _owner) public view returns (uint) {
        if (troveManager.getTroveStatus(_owner) != 1) return 0;
        (, uint coll, , ) = troveManager.getEntireDebtAndColl(_owner);
        (, , uint baseline) = borrowerOperations.autoRepay(_owner);
        uint base = baseline * 1e18 / IDeskWstETH(address(collateralToken)).stEthPerToken();
        return coll > base ? coll - base : 0;
    }

    // A keeper's skim is worth doing when the owner opted in, the cadence period has passed, the reserve has
    // inventory, and the yield covers the period's interest. Returns the keeper's cut at today's price.
    function _checkSkim(address _owner, uint _price, Rewards memory _r) internal view returns (bool, uint) {
        (uint8 cadence, uint64 lastSkim, uint baseline) = borrowerOperations.autoRepay(_owner);
        if (cadence == 0 || _r.inventory == 0) return (false, 0);
        uint period = cadence == 1 ? 30 days : cadence == 2 ? 91 days : 365 days;
        if (block.timestamp < uint(lastSkim) + period) return (false, 0);
        (uint debt, uint coll, , ) = troveManager.getEntireDebtAndColl(_owner);
        uint base = baseline * 1e18 / _r.rate;
        uint yield = coll > base ? coll - base : 0;
        uint oct = yield * _price / (1e18 + _r.premium);
        if (oct > _r.inventory) oct = _r.inventory;
        if (oct < debt * _r.ratePerYear * period / 365 days / 1e18) return (false, 0);
        uint cut = oct * _r.cutBps / 10000;
        return (true, cut < _r.cutCap ? cut : _r.cutCap);
    }
}
