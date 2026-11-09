// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Keeper desk: one call that does every piece of pending housekeeping and hands every reward the protocol
* already pays to whoever made the call. Periphery: holds no funds between calls, has no owner, changes no
* rule. Anyone may call it; a bot, a wallet, a browser button.
*
* What a run does, in order: accrue interest; release reserve surplus if one is due; liquidate the vaults
* passed in (the protocol pays 200 OCT plus 0.5% of the collateral per vault, Liquity's gas compensation);
* execute the successions passed in (the protocol pays the estate's executor reward); then sweep the OCT
* and collateral this contract received to the caller. Steps that have nothing to do are skipped, never
* reverted, so a run always finishes. `pending()` is the matching read: it scans the riskiest vaults and
* reports what a run would do and roughly what it would pay.
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
}
interface IDeskSortedTroves { function getLast() external view returns (address); function getPrev(address id) external view returns (address); function getSize() external view returns (uint); }
interface IDeskPriceFeed { function peek() external view returns (uint price, bool healthy); }
interface IDeskBuffer { function releaseSurplus() external returns (uint); }
interface IDeskRegistry {
    function successionState(address owner) external view returns (uint8 state, uint dueAt, uint executableAt);
    function execute(address owner) external;
    function REWARD_BPS() external view returns (uint);
    function REWARD_CAP() external view returns (uint);
}
interface IDeskERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); }

contract KeeperDesk {
    IDeskTroveManager public immutable troveManager;
    IDeskSortedTroves public immutable sortedTroves;
    IDeskPriceFeed public immutable priceFeed;
    IDeskBuffer public immutable redemptionBuffer;
    IDeskRegistry public immutable successionRegistry;
    IDeskERC20 public immutable octToken;
    IDeskERC20 public immutable collateralToken;

    event Run(address indexed caller, uint liquidated, uint executed, uint surplusReleased, uint octPaid, uint collPaid);

    constructor(address _troveManager, address _sortedTroves, address _priceFeed, address _buffer, address _registry, address _oct, address _coll) {
        troveManager = IDeskTroveManager(_troveManager);
        sortedTroves = IDeskSortedTroves(_sortedTroves);
        priceFeed = IDeskPriceFeed(_priceFeed);
        redemptionBuffer = IDeskBuffer(_buffer);
        successionRegistry = IDeskRegistry(_registry);
        octToken = IDeskERC20(_oct);
        collateralToken = IDeskERC20(_coll);
    }

    /// Everything pending, in one transaction. Rewards go to the caller.
    function run(address[] calldata _liquidate, address[] calldata _execute) external returns (uint octPaid, uint collPaid) {
        troveManager.accrueInterest();

        uint released;
        try redemptionBuffer.releaseSurplus() returns (uint amount) { released = amount; } catch {}

        uint liquidated;
        if (_liquidate.length > 0) {
            try troveManager.batchLiquidateTroves(_liquidate) { liquidated = _liquidate.length; } catch {}
        }

        uint executed;
        for (uint i = 0; i < _execute.length; i++) {
            try successionRegistry.execute(_execute[i]) { executed++; } catch {}
        }

        octPaid = octToken.balanceOf(address(this));
        collPaid = collateralToken.balanceOf(address(this));
        if (octPaid > 0) require(octToken.transfer(msg.sender, octPaid), "KeeperDesk: OCT transfer failed");
        if (collPaid > 0) require(collateralToken.transfer(msg.sender, collPaid), "KeeperDesk: collateral transfer failed");
        emit Run(msg.sender, liquidated, executed, released, octPaid, collPaid);
    }

    struct Rewards { uint threshold; uint gasComp; uint divisor; uint rewardBps; uint rewardCap; }
    struct Pending { uint price; bool oracleHealthy; bool recoveryMode; address[] liquidatable; address[] executable; uint octReward; uint collReward; }

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
            rewardCap: successionRegistry.REWARD_CAP()
        });

        uint n = sortedTroves.getSize();
        if (n > _maxScan) n = _maxScan;
        address[] memory liq = new address[](n);
        address[] memory exe = new address[](n);
        uint nl; uint ne;

        address owner = sortedTroves.getLast();
        for (uint i = 0; i < n && owner != address(0); i++) {
            (bool isLiq, bool isExe, uint octAdd, uint collAdd) = _check(owner, w.price, r);
            if (isLiq) liq[nl++] = owner;
            if (isExe) exe[ne++] = owner;
            w.octReward += octAdd;
            w.collReward += collAdd;
            owner = sortedTroves.getPrev(owner);
        }

        w.liquidatable = new address[](nl);
        w.executable = new address[](ne);
        for (uint i = 0; i < nl; i++) w.liquidatable[i] = liq[i];
        for (uint i = 0; i < ne; i++) w.executable[i] = exe[i];
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
}
