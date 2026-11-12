// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedTroves.sol";
import "../legacystack/Interfaces/IRedemptionBuffer.sol";
import "../legacystack/Interfaces/ISuccessionRegistry.sol";
import "../legacystack/Interfaces/IWstETH.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/IERC20.sol";

contract BorrowerOperations is LiquityBase, Ownable, CheckContract, IBorrowerOperations {
    string constant public NAME = "BorrowerOperations";

    // --- Connected contract declarations ---

    ITroveManager public troveManager;

    address stabilityPoolAddress;

    address gasPoolAddress;

    ICollSurplusPool collSurplusPool;

    IRedemptionBuffer public redemptionBuffer;      // LegacyStack: receives mint fees (OCT) and sets the debt ceiling
    ISuccessionRegistry public successionRegistry;  // LegacyStack: succession settlement (the registry closes estates)
    IERC20 public collateralToken;                  // LegacyStack: wstETH
    address public redemptionBufferAddress;

    // LegacyStack auto-repay from staking rewards (#160, #161). baseline = the vault's collateral in stETH
    // units at its last sync (coll x Lido rate); the skimmable yield is whatever Lido's rate growth added on top.
    struct AutoRepay { uint8 cadence; uint64 lastSkim; uint baseline; }
    mapping(address => AutoRepay) public override autoRepay;
    uint constant public SKIM_CUT_BPS = 100;        // the keeper's cut: 1% of the OCT bought ...
    uint constant public SKIM_CUT_CAP = 5e18;       // ... and never more than 5 OCT
    uint constant public SETTLE_POOL_PREMIUM = 2e16; // a settlement pays the Stability Pool 2% over par for the OCT it provides (#170)

    ILUSDToken public lusdToken;

    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves public sortedTroves;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

     struct LocalVariables_adjustTrove {
        uint price;
        uint collChange;
        uint netDebtChange;
        bool isCollIncrease;
        uint debt;
        uint coll;
        uint oldICR;
        uint newICR;
        uint newTCR;
        uint LUSDFee;
        uint newDebt;
        uint newColl;
        uint stake;
    }

    struct LocalVariables_openTrove {
        uint price;
        uint LUSDFee;
        uint netDebt;
        uint compositeDebt;
        uint ICR;
        uint NICR;
        uint stake;
        uint arrayIndex;
    }

    struct ContractsCache {
        ITroveManager troveManager;
        IActivePool activePool;
        ILUSDToken lusdToken;
    }

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove,
        settleForSuccession
    }

    struct LocalVariables_skim {
        uint price;
        uint rate;
        uint coll;
        uint debt;
        uint collYield;
        uint oct;
        uint collIn;
        uint cut;
        uint repay;
        uint toOwner;
        uint maxRepay;
        uint stake;
        bool byOwner;
        bool capped;
    }

    struct LocalVariables_settle {
        uint price;
        uint settlePrice;
        uint liquidity;
        uint toSettle;
        uint debt;
        uint coll;
        uint netDebt;
        uint octUsed;
        uint fromBuffer;
        uint fromSP;
        uint collOut;
        uint collRemoved;
        uint spAvailable;
        uint settled;
        uint stake;
    }

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event LUSDTokenAddressChanged(address _lusdTokenAddress);
    event RedemptionBufferAddressChanged(address _redemptionBufferAddress);
    event SuccessionRegistryAddressChanged(address _successionRegistryAddress);

    event TroveCreated(address indexed _borrower, uint arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, BorrowerOperation operation);
    event LUSDBorrowingFeePaid(address indexed _borrower, uint _LUSDFee);
    
    // --- Dependency setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _sortedTrovesAddress,
        address _lusdTokenAddress,
        address _redemptionBufferAddress,
        address _collateralTokenAddress,
        address _successionRegistryAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_collateralTokenAddress);
        checkContract(_successionRegistryAddress);
        collateralToken = IERC20(_collateralTokenAddress);
        successionRegistry = ISuccessionRegistry(_successionRegistryAddress);
        // This makes impossible to open a trove with zero withdrawn LUSD
        assert(MIN_NET_DEBT > 0);

        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_gasPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_priceFeedAddress);
        checkContract(_sortedTrovesAddress);
        checkContract(_lusdTokenAddress);
        checkContract(_redemptionBufferAddress);

        troveManager = ITroveManager(_troveManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPoolAddress = _stabilityPoolAddress;
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        redemptionBufferAddress = _redemptionBufferAddress;
        redemptionBuffer = IRedemptionBuffer(_redemptionBufferAddress);

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit GasPoolAddressChanged(_gasPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
        emit RedemptionBufferAddressChanged(_redemptionBufferAddress);
        emit SuccessionRegistryAddressChanged(_successionRegistryAddress);

        _renounceOwnership();
    }

    // --- Borrower Trove Operations ---

    function openTrove(uint _maxFeePercentage, uint _LUSDAmount, address _upperHint, address _lowerHint, uint _collAmount) external override {
        troveManager.accrueInterest();
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, lusdToken);
        LocalVariables_openTrove memory vars;

        vars.price = priceFeed.lowerOfMarket(priceFeed.fetchPrice());   // new risk is priced at the lower of canonical and market (#162)
        _requireOracleHealthy();
        bool isRecoveryMode = _checkRecoveryMode(vars.price);

        _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
        _requireTroveisNotActive(contractsCache.troveManager, msg.sender);

        vars.LUSDFee;
        vars.netDebt = _LUSDAmount;

        if (!isRecoveryMode) {
            vars.LUSDFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.lusdToken, _LUSDAmount, _maxFeePercentage);
            vars.netDebt = vars.netDebt.add(vars.LUSDFee);
        }
        _requireAtLeastMinNetDebt(vars.netDebt);

        // ICR is based on the composite debt, i.e. the requested LUSD amount + LUSD borrowing fee + LUSD gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);
        assert(vars.compositeDebt > 0);
        _requireUnderDebtCeiling(vars.price, vars.compositeDebt);
        
        vars.ICR = LiquityMath._computeCR(_collAmount, vars.compositeDebt, vars.price);
        vars.NICR = LiquityMath._computeNominalCR(_collAmount, vars.compositeDebt);

        if (isRecoveryMode) {
            _requireICRisAboveCCR(vars.ICR);
        } else {
            _requireICRisAboveMCR(vars.ICR);
            uint newTCR = _getNewTCRFromTroveChange(_collAmount, true, vars.compositeDebt, true, vars.price);  // bools: coll increase, debt increase
            _requireNewTCRisAboveCCR(newTCR); 
        }

        // Set the trove struct's properties
        contractsCache.troveManager.setTroveStatus(msg.sender, 1);
        contractsCache.troveManager.increaseTroveColl(msg.sender, _collAmount);
        contractsCache.troveManager.increaseTroveDebt(msg.sender, vars.compositeDebt);

        contractsCache.troveManager.updateTroveRewardSnapshots(msg.sender);
        vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);
        autoRepay[msg.sender].baseline = _collAmount.mul(_lidoRate()).div(DECIMAL_PRECISION);

        sortedTroves.insert(msg.sender, vars.NICR, _upperHint, _lowerHint);
        vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(msg.sender);
        emit TroveCreated(msg.sender, vars.arrayIndex);

        // Move the ether to the Active Pool, and mint the LUSDAmount to the borrower
        _activePoolAddColl(contractsCache.activePool, _collAmount);
        _withdrawLUSD(contractsCache.activePool, contractsCache.lusdToken, msg.sender, _LUSDAmount, vars.netDebt);
        // Move the LUSD gas compensation to the Gas Pool
        _withdrawLUSD(contractsCache.activePool, contractsCache.lusdToken, gasPoolAddress, LUSD_GAS_COMPENSATION, LUSD_GAS_COMPENSATION);

        emit TroveUpdated(msg.sender, vars.compositeDebt, _collAmount, vars.stake, BorrowerOperation.openTrove);
        emit LUSDBorrowingFeePaid(msg.sender, vars.LUSDFee);
    }

    // Send ETH as collateral to a trove
    function addColl(address _upperHint, address _lowerHint, uint _collAmount) external override {
        _adjustTrove(msg.sender, _collAmount, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Send ETH as collateral to a trove. Called by only the Stability Pool.
    function moveETHGainToTrove(address _borrower, address _upperHint, address _lowerHint, uint _collAmount) external override {
        _requireCallerIsStabilityPool();
        _adjustTrove(_borrower, _collAmount, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw ETH collateral from a trove
    function withdrawColl(uint _collWithdrawal, address _upperHint, address _lowerHint) external override {
        _adjustTrove(msg.sender, 0, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw LUSD tokens from a trove: mint new LUSD tokens to the owner, and increase the trove's debt accordingly
    function withdrawLUSD(uint _maxFeePercentage, uint _LUSDAmount, address _upperHint, address _lowerHint) external override {
        _adjustTrove(msg.sender, 0, 0, _LUSDAmount, true, _upperHint, _lowerHint, _maxFeePercentage);
    }

    // Repay LUSD tokens to a Trove: Burn the repaid LUSD tokens, and reduce the trove's debt accordingly
    function repayLUSD(uint _LUSDAmount, address _upperHint, address _lowerHint) external override {
        _adjustTrove(msg.sender, 0, 0, _LUSDAmount, false, _upperHint, _lowerHint, 0);
    }

    function adjustTrove(uint _maxFeePercentage, uint _collWithdrawal, uint _LUSDChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint _collDeposit) external override {
        _adjustTrove(msg.sender, _collDeposit, _collWithdrawal, _LUSDChange, _isDebtIncrease, _upperHint, _lowerHint, _maxFeePercentage);
    }

    // LegacyStack (#161): anyone may add collateral to any active vault, from their own balance. The only thing
    // a third party can do to a vault is make it safer; it never counts as the owner's sign of life.
    function addCollateralFor(address _owner, address _upperHint, address _lowerHint, uint _collAmount) external override {
        _adjustTrove(_owner, _collAmount, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    /*
    * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal. 
    *
    * It therefore expects either a positive _collDeposit (ERC-20 collateral pulled from msg.sender), or a positive _collWithdrawal argument.
    *
    * If both are positive, it will revert.
    */
    function _adjustTrove(address _borrower, uint _collDeposit, uint _collWithdrawal, uint _LUSDChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint _maxFeePercentage) internal {
        troveManager.accrueInterest();
        ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, lusdToken);
        LocalVariables_adjustTrove memory vars;

        vars.price = priceFeed.fetchPrice();
        if (_isDebtIncrease || _collWithdrawal > 0) {
            _requireOracleHealthy();                                   // reduce-only state (#141)
            vars.price = priceFeed.lowerOfMarket(vars.price);          // new risk at the lower of canonical and market (#162)
        }
        bool isRecoveryMode = _checkRecoveryMode(vars.price);

        if (_isDebtIncrease) {
            _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
            _requireNonZeroDebtChange(_LUSDChange);
        }
        _requireSingularCollChange(_collDeposit, _collWithdrawal);
        _requireNonZeroAdjustment(_collDeposit, _collWithdrawal, _LUSDChange);
        _requireTroveisActive(contractsCache.troveManager, _borrower);

        // Who may adjust: the owner does anything; anyone else (the Stability Pool moving a collateral gain, a
        // family member or a keeper adding collateral) may only add collateral from its own balance.
        if (msg.sender != _borrower) {
            require(_collDeposit > 0 && _LUSDChange == 0 && _collWithdrawal == 0, "others may only add collateral");
        }

        _syncBaseline(contractsCache.troveManager, _borrower);

        // Get the collChange based on whether or not ETH was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(_collDeposit, _collWithdrawal);

        vars.netDebtChange = _LUSDChange;

        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (_isDebtIncrease && !isRecoveryMode) { 
            vars.LUSDFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.lusdToken, _LUSDChange, _maxFeePercentage);
            vars.netDebtChange = vars.netDebtChange.add(vars.LUSDFee); // The raw debt change includes the fee
        }

        vars.debt = contractsCache.troveManager.getTroveDebt(_borrower);
        vars.coll = contractsCache.troveManager.getTroveColl(_borrower);
        
        // Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
        vars.oldICR = LiquityMath._computeCR(vars.coll, vars.debt, vars.price);
        vars.newICR = _getNewICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, vars.price);
        assert(_collWithdrawal <= vars.coll); 

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(isRecoveryMode, _collWithdrawal, _isDebtIncrease, vars);
        if (_isDebtIncrease) { _requireUnderDebtCeiling(vars.price, vars.netDebtChange); }

        // When the adjustment is a debt repayment, check it's a valid amount and that the payer (msg.sender) has enough OCT
        if (!_isDebtIncrease && _LUSDChange > 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt).sub(vars.netDebtChange));
            _requireValidLUSDRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientLUSDBalance(contractsCache.lusdToken, msg.sender, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(contractsCache.troveManager, _borrower, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        _moveBaseline(_borrower, vars.collChange, vars.isCollIncrease);
        vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(_borrower);

        // Re-insert trove in to the sorted list
        uint newNICR = _getNewNominalICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        sortedTroves.reInsert(_borrower, newNICR, _upperHint, _lowerHint);

        emit TroveUpdated(_borrower, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustTrove);
        emit LUSDBorrowingFeePaid(msg.sender,  vars.LUSDFee);

        // Use the unmodified _LUSDChange here, as we don't send the fee to the user.
        // Pulls (collateral deposit, repayment) come from msg.sender; pushes (borrowed OCT, withdrawn collateral) go to the owner.
        _moveTokensAndETHfromAdjustment(
            contractsCache.activePool,
            contractsCache.lusdToken,
            _borrower,
            vars.collChange,
            vars.isCollIncrease,
            _LUSDChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeTrove() external override {
        troveManager.accrueInterest();
        ITroveManager troveManagerCached = troveManager;
        IActivePool activePoolCached = activePool;
        ILUSDToken lusdTokenCached = lusdToken;

        _requireTroveisActive(troveManagerCached, msg.sender);
        uint price = priceFeed.fetchPrice();
        _requireNotInRecoveryMode(price);

        troveManagerCached.applyPendingRewards(msg.sender);

        uint coll = troveManagerCached.getTroveColl(msg.sender);
        uint debt = troveManagerCached.getTroveDebt(msg.sender);

        _requireSufficientLUSDBalance(lusdTokenCached, msg.sender, debt.sub(LUSD_GAS_COMPENSATION));

        uint newTCR = _getNewTCRFromTroveChange(coll, false, debt, false, price);
        _requireNewTCRisAboveCCR(newTCR);

        troveManagerCached.removeStake(msg.sender);
        troveManagerCached.closeTrove(msg.sender);
        delete autoRepay[msg.sender];

        emit TroveUpdated(msg.sender, 0, 0, 0, BorrowerOperation.closeTrove);

        // Burn the repaid LUSD from the user's balance and the gas compensation from the Gas Pool
        _repayLUSD(activePoolCached, lusdTokenCached, msg.sender, debt.sub(LUSD_GAS_COMPENSATION));
        _repayLUSD(activePoolCached, lusdTokenCached, gasPoolAddress, LUSD_GAS_COMPENSATION);

        // Send the collateral back to the user
        activePoolCached.sendETH(msg.sender, coll);
    }

    // --- LegacyStack auto-repay from staking rewards (#160, #161) ---

    function setAutoRepay(uint8 _cadence) external override {
        require(_cadence <= 3, "cadence 0-3");
        AutoRepay storage a = autoRepay[msg.sender];
        if (_cadence != 0 && a.cadence == 0) { a.lastSkim = uint64(block.timestamp); } // the first keeper skim is one period away
        a.cadence = _cadence;
        emit AutoRepaySet(msg.sender, _cadence);
    }

    /*
    * Sell the vault's accrued staking yield to the reserve and repay the vault with the OCT. The yield is the
    * wstETH that Lido's rate growth added above the baseline, so the vault's stETH-denominated collateral never
    * falls below the baseline. The reserve pays par + its premium; the OCT burned here is debt that disappears
    * without a market leg, and the wstETH stays in the reserve. Nothing moves if the reserve has no inventory.
    */
    function skimYield(address _owner, address _upperHint, address _lowerHint) external override {
        ContractsCache memory c = ContractsCache(troveManager, activePool, lusdToken);
        LocalVariables_skim memory v;
        c.troveManager.accrueInterest();
        _requireTroveisActive(c.troveManager, _owner);
        v.price = priceFeed.fetchPrice();
        _requireOracleHealthy();
        _requireNotInRecoveryMode(v.price);

        AutoRepay storage a = autoRepay[_owner];
        v.byOwner = msg.sender == _owner;
        if (!v.byOwner) {
            require(a.cadence != 0, "auto-repay off");
            require(block.timestamp >= uint(a.lastSkim).add(_period(a.cadence)), "not due yet");
        }

        _syncBaseline(c.troveManager, _owner);
        v.rate = _lidoRate();
        v.coll = c.troveManager.getTroveColl(_owner);
        v.debt = c.troveManager.getTroveDebt(_owner);
        v.collYield = _yieldAbove(v.coll, a.baseline, v.rate);
        v.price = priceFeed.lowerOfMarket(v.price);                    // the reserve buys the yield at the offer price (#162)

        // OCT the yield buys at the standing offer, capped by the inventory
        v.oct = v.collYield.mul(v.price).div(DECIMAL_PRECISION.add(redemptionBuffer.OFFER_PREMIUM()));
        require(v.oct > 0, "no yield yet");
        uint inventory = redemptionBuffer.inventory();
        if (v.oct > inventory) { v.oct = inventory; v.capped = true; }
        require(v.oct > 0, "no inventory");
        if (!v.byOwner) {
            uint periodInterest = v.debt.mul(c.troveManager.RATE_PER_YEAR()).mul(_period(a.cadence)).div(365 days).div(DECIMAL_PRECISION);
            require(v.oct >= periodInterest, "yield below interest");
        }
        v.collIn = redemptionBuffer.quoteInventory(v.oct, v.price);
        assert(v.collIn <= v.collYield);

        // Split: the keeper's cut, the repayment (never below the minimum net debt), the rest to the owner
        v.cut = v.byOwner ? 0 : LiquityMath._min(v.oct.mul(SKIM_CUT_BPS).div(10000), SKIM_CUT_CAP);
        v.repay = v.oct.sub(v.cut);
        v.maxRepay = _getNetDebt(v.debt) > MIN_NET_DEBT ? _getNetDebt(v.debt).sub(MIN_NET_DEBT) : 0;
        if (v.repay > v.maxRepay) { v.toOwner = v.repay.sub(v.maxRepay); v.repay = v.maxRepay; }

        // Move the yield to the reserve, take the OCT, burn the repayment straight from the reserve's balance
        c.troveManager.decreaseTroveColl(_owner, v.collIn);
        c.activePool.sendETH(redemptionBufferAddress, v.collIn);
        redemptionBuffer.serveSkim(_owner, v.oct, v.collIn, msg.sender, v.cut, v.toOwner);
        if (v.repay > 0) {
            _repayLUSD(c.activePool, c.lusdToken, redemptionBufferAddress, v.repay);
            v.debt = c.troveManager.decreaseTroveDebt(_owner, v.repay);
        }
        v.coll = v.coll.sub(v.collIn);
        _requireICRisAboveMCR(LiquityMath._computeCR(v.coll, v.debt, v.price));
        // A full skim leaves the vault exactly at its baseline (rounded up by a wei of stETH, so no dust is ever
        // read as yield); a skim capped by the inventory keeps the baseline, and the rest stays skimmable.
        if (!v.capped) { a.baseline = v.coll.mul(v.rate).add(DECIMAL_PRECISION.sub(1)).div(DECIMAL_PRECISION); }

        v.stake = c.troveManager.updateStakeAndTotalStakes(_owner);
        sortedTroves.reInsert(_owner, LiquityMath._computeNominalCR(v.coll, v.debt), _upperHint, _lowerHint);
        a.lastSkim = uint64(block.timestamp);

        emit TroveUpdated(_owner, v.debt, v.coll, v.stake, BorrowerOperation.adjustTrove);
        emit YieldSkimmed(_owner, msg.sender, v.collIn, v.oct, v.repay, v.cut, v.toOwner);
    }

    function _period(uint8 _cadence) internal pure returns (uint) {
        if (_cadence == 1) { return 30 days; }
        if (_cadence == 2) { return 91 days; }
        return 365 days;
    }

    function _lidoRate() internal view returns (uint) {
        return IWstETH(address(collateralToken)).stEthPerToken();
    }

    // wstETH above the baseline at the current rate: coll - baseline / rate
    function _yieldAbove(uint _coll, uint _baseline, uint _rate) internal pure returns (uint) {
        uint base = _baseline.mul(DECIMAL_PRECISION).div(_rate);
        return _coll > base ? _coll.sub(base) : 0;
    }

    // Apply the vault's pending redistribution rewards and keep the baseline honest: collateral that arrived
    // from a redistribution is not yield, and collateral that left outside BorrowerOperations (a redemption)
    // cannot leave a baseline above the vault.
    function _syncBaseline(ITroveManager _troveManager, address _borrower) internal {
        uint gain = _troveManager.getPendingETHReward(_borrower);
        _troveManager.applyPendingRewards(_borrower);
        uint rate = _lidoRate();
        AutoRepay storage a = autoRepay[_borrower];
        uint baseline = a.baseline.add(gain.mul(rate).div(DECIMAL_PRECISION));
        uint collValue = _troveManager.getTroveColl(_borrower).mul(rate).add(DECIMAL_PRECISION.sub(1)).div(DECIMAL_PRECISION);
        a.baseline = baseline > collValue ? collValue : baseline;
    }

    // The owner's own deposits and withdrawals move the baseline with them, so they are never read as yield.
    function _moveBaseline(address _borrower, uint _collChange, bool _isCollIncrease) internal {
        if (_collChange == 0) { return; }
        AutoRepay storage a = autoRepay[_borrower];
        uint delta = _collChange.mul(_lidoRate()).div(DECIMAL_PRECISION);
        if (_isCollIncrease) { a.baseline = a.baseline.add(delta); }
        else { a.baseline = a.baseline > delta ? a.baseline.sub(delta) : 0; }
    }

    /**
     * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
     */
    function claimCollateral() external override {
        // send ETH from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender);
    }

    // LegacyStack succession: the registry collects an owner's surplus collateral for the heirs.
    function claimCollateralForSuccession(address _owner, address _to) external override {
        _requireCallerIsSuccessionRegistry();
        collSurplusPool.claimCollTo(_owner, _to);
    }

    /*
    * LegacyStack succession settlement (#135, #136). Order of OCT sources: the estate's own OCT held by the
    * registry, then the Redemption Buffer's inventory (the buffer receives collateral worth exactly the OCT it
    * gives, at the oracle price), then the Stability Pool (an offset at par: depositors receive collateral worth
    * exactly the OCT cancelled). Closes the vault once the net debt is zero and sends the remaining collateral
    * to the registry. If liquidity is short the vault stays open with less debt and less collateral, at a
    * higher collateral ratio, and the call can be repeated later. Nothing here reads a market price.
    */
    function settleForSuccession(address _owner, uint _octAvailable) external override returns (uint, bool, uint) {
        _requireCallerIsSuccessionRegistry();
        ContractsCache memory c = ContractsCache(troveManager, activePool, lusdToken);
        _requireTroveisActive(c.troveManager, _owner);
        c.troveManager.accrueInterest();
        LocalVariables_settle memory v;
        v.price = priceFeed.fetchPrice();
        if (!priceFeed.isWindDown()) { require(!priceFeed.isReduceOnly(), "succession waits for the oracle"); }
        c.troveManager.applyPendingRewards(_owner);
        v.debt = c.troveManager.getTroveDebt(_owner);
        v.coll = c.troveManager.getTroveColl(_owner);
        v.netDebt = v.debt.sub(LUSD_GAS_COMPENSATION);
        // An estate under the liquidation line is liquidated like any vault, never settled at par (KupiaSec, 10 Nov 2026)
        require(LiquityMath._computeCR(v.coll, v.debt, v.price) >= MCR, "under 110%: liquidate");

        // The price the settlement pays collateral out at. End state (#160): the stale price with a 20% haircut,
        // in the estate's disfavour, capped so that the collateral still covers the debt plus the pool's premium.
        v.settlePrice = v.price;
        if (priceFeed.isWindDown()) {
            v.settlePrice = LiquityMath._max(v.price.mul(80).div(100), v.netDebt.mul(DECIMAL_PRECISION.add(SETTLE_POOL_PREMIUM)).div(v.coll).add(1));
        }

        // How much can be settled today: everything, or, if the liquidity is short, a partial amount that leaves
        // the vault at or above the minimum net debt (never a dust vault in the list).
        v.spAvailable = IStabilityPool(stabilityPoolAddress).getTotalLUSDDeposits();
        v.spAvailable = v.spAvailable > 1e18 ? v.spAvailable.sub(1e18) : 0;
        v.liquidity = _octAvailable.add(c.lusdToken.balanceOf(redemptionBufferAddress)).add(v.spAvailable);
        if (v.liquidity >= v.netDebt) {
            v.toSettle = v.netDebt;
        } else {
            v.toSettle = v.netDebt > MIN_NET_DEBT ? LiquityMath._min(v.liquidity, v.netDebt.sub(MIN_NET_DEBT)) : 0;
            if (v.toSettle == 0) { return (0, false, 0); }
        }

        // 1. The estate's own OCT, held by the registry.
        v.octUsed = LiquityMath._min(v.toSettle, _octAvailable);
        if (v.octUsed > 0) {
            _repayLUSD(c.activePool, c.lusdToken, msg.sender, v.octUsed);
            v.toSettle = v.toSettle.sub(v.octUsed);
        }

        // 2. Redemption Buffer inventory at the settlement price plus the standing offer's premium: the estate pays
        //    what any borrower pays for the reserve's OCT (#170).
        v.fromBuffer = LiquityMath._min(v.toSettle, c.lusdToken.balanceOf(redemptionBufferAddress));
        if (v.fromBuffer > 0) {
            v.collOut = v.fromBuffer.mul(DECIMAL_PRECISION.add(redemptionBuffer.OFFER_PREMIUM())).div(v.settlePrice);
            _repayLUSD(c.activePool, c.lusdToken, redemptionBufferAddress, v.fromBuffer);
            c.activePool.sendETH(redemptionBufferAddress, v.collOut);
            v.toSettle = v.toSettle.sub(v.fromBuffer);
            v.collRemoved = v.collRemoved.add(v.collOut);
        }

        // 3. Stability Pool offset at the settlement price plus 2%: the depositors are paid for providing the OCT
        //    (#170; the pool keeps its minimum balance).
        v.fromSP = LiquityMath._min(v.toSettle, v.spAvailable);
        if (v.fromSP > 0) {
            v.collOut = v.fromSP.mul(DECIMAL_PRECISION.add(SETTLE_POOL_PREMIUM)).div(v.settlePrice);
            IStabilityPool(stabilityPoolAddress).offset(v.fromSP, v.collOut); // burns from the pool, decreases active debt, moves the collateral
            v.toSettle = v.toSettle.sub(v.fromSP);
            v.collRemoved = v.collRemoved.add(v.collOut);
        }
        v.netDebt = v.netDebt.sub(v.octUsed).sub(v.fromBuffer).sub(v.fromSP);

        v.settled = v.octUsed.add(v.fromBuffer).add(v.fromSP);
        if (v.settled > 0) { c.troveManager.decreaseTroveDebt(_owner, v.settled); }
        if (v.collRemoved > 0) { c.troveManager.decreaseTroveColl(_owner, v.collRemoved); }
        v.coll = v.coll.sub(v.collRemoved);

        if (v.netDebt == 0) {
            // Close: the gas compensation is burned from the Gas Pool, the collateral goes to the registry.
            _repayLUSD(c.activePool, c.lusdToken, gasPoolAddress, LUSD_GAS_COMPENSATION);
            c.troveManager.removeStake(_owner);
            c.troveManager.closeTroveBySuccession(_owner);
            delete autoRepay[_owner];
            c.activePool.sendETH(msg.sender, v.coll);
            emit TroveUpdated(_owner, 0, 0, 0, BorrowerOperation.settleForSuccession);
            return (v.octUsed, true, v.coll);
        }

        // Partial: keep the vault in the sorted list at its new, higher ratio.
        v.stake = c.troveManager.updateStakeAndTotalStakes(_owner);
        v.debt = v.netDebt.add(LUSD_GAS_COMPENSATION);
        sortedTroves.reInsert(_owner, LiquityMath._computeNominalCR(v.coll, v.debt), address(0), address(0));
        emit TroveUpdated(_owner, v.debt, v.coll, v.stake, BorrowerOperation.settleForSuccession);
        return (v.octUsed, false, 0);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(ITroveManager _troveManager, ILUSDToken _lusdToken, uint _LUSDAmount, uint _maxFeePercentage) internal returns (uint) {
        _troveManager.decayBaseRateFromBorrowing(); // decay the baseRate state variable
        uint LUSDFee = _troveManager.getBorrowingFee(_LUSDAmount);

        _requireUserAcceptsFee(LUSDFee, _LUSDAmount, _maxFeePercentage);

        // LegacyStack: the mint fee is OCT inventory in the Redemption Buffer (#101)
        _lusdToken.mint(redemptionBufferAddress, LUSDFee);

        return LUSDFee;
    }

    function _getUSDValue(uint _coll, uint _price) internal pure returns (uint) {
        uint usdValue = _price.mul(_coll).div(DECIMAL_PRECISION);

        return usdValue;
    }

    function _getCollChange(
        uint _collReceived,
        uint _requestedCollWithdrawal
    )
        internal
        pure
        returns(uint collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update trove's coll and debt based on whether they increase or decrease
    function _updateTroveFromAdjustment
    (
        ITroveManager _troveManager,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        returns (uint, uint)
    {
        uint newColl = (_isCollIncrease) ? _troveManager.increaseTroveColl(_borrower, _collChange)
                                        : _troveManager.decreaseTroveColl(_borrower, _collChange);
        uint newDebt = (_isDebtIncrease) ? _troveManager.increaseTroveDebt(_borrower, _debtChange)
                                        : _troveManager.decreaseTroveDebt(_borrower, _debtChange);

        return (newColl, newDebt);
    }

    function _moveTokensAndETHfromAdjustment
    (
        IActivePool _activePool,
        ILUSDToken _lusdToken,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _LUSDChange,
        bool _isDebtIncrease,
        uint _netDebtChange
    )
        internal
    {
        if (_isDebtIncrease) {
            _withdrawLUSD(_activePool, _lusdToken, _borrower, _LUSDChange, _netDebtChange);
        } else {
            _repayLUSD(_activePool, _lusdToken, msg.sender, _LUSDChange);
        }

        if (_isCollIncrease) {
            _activePoolAddColl(_activePool, _collChange);
        } else {
            _activePool.sendETH(_borrower, _collChange);
        }
    }

    // Send ETH to Active Pool and increase its recorded ETH balance
    function _activePoolAddColl(IActivePool _activePool, uint _amount) internal {
        require(collateralToken.transferFrom(msg.sender, address(_activePool), _amount), "collateral pull failed");
        _activePool.receiveCollateral(_amount);
    }

    // Issue the specified amount of LUSD to _account and increases the total active debt (_netDebtIncrease potentially includes a LUSDFee)
    function _withdrawLUSD(IActivePool _activePool, ILUSDToken _lusdToken, address _account, uint _LUSDAmount, uint _netDebtIncrease) internal {
        _activePool.increaseLUSDDebt(_netDebtIncrease);
        _lusdToken.mint(_account, _LUSDAmount);
    }

    // Burn the specified amount of LUSD from _account and decreases the total active debt
    function _repayLUSD(IActivePool _activePool, ILUSDToken _lusdToken, address _account, uint _LUSD) internal {
        _activePool.decreaseLUSDDebt(_LUSD);
        _lusdToken.burn(_account, _LUSD);
    }

    // --- 'Require' wrapper functions ---

    function _requireSingularCollChange(uint _collDeposit, uint _collWithdrawal) internal pure {
        require(_collDeposit == 0 || _collWithdrawal == 0, "withdraw or add, not both");
    }

    function _requireCallerIsBorrower(address _borrower) internal view {
        require(msg.sender == _borrower, "not the owner");
    }

    function _requireNonZeroAdjustment(uint _collDeposit, uint _collWithdrawal, uint _LUSDChange) internal pure {
        require(_collDeposit != 0 || _collWithdrawal != 0 || _LUSDChange != 0, "nothing to change");
    }

    function _requireTroveisActive(ITroveManager _troveManager, address _borrower) internal view {
        uint status = _troveManager.getTroveStatus(_borrower);
        require(status == 1, "no open vault");
    }

    function _requireTroveisNotActive(ITroveManager _troveManager, address _borrower) internal view {
        uint status = _troveManager.getTroveStatus(_borrower);
        require(status != 1, "Trove is active");
    }

    function _requireNonZeroDebtChange(uint _LUSDChange) internal pure {
        require(_LUSDChange > 0, "zero debt change");
    }
   
    function _requireNotInRecoveryMode(uint _price) internal view {
        require(!_checkRecoveryMode(_price), "not in Recovery Mode");
    }

    function _requireNoCollWithdrawal(uint _collWithdrawal) internal pure {
        require(_collWithdrawal == 0, "no withdrawals in Recovery Mode");
    }

    function _requireValidAdjustmentInCurrentMode 
    (
        bool _isRecoveryMode,
        uint _collWithdrawal,
        bool _isDebtIncrease, 
        LocalVariables_adjustTrove memory _vars
    ) 
        internal 
        view 
    {
        /* 
        *In Recovery Mode, only allow:
        *
        * - Pure collateral top-up
        * - Pure debt repayment
        * - Collateral top-up with debt repayment
        * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
        *
        * In Normal Mode, ensure:
        *
        * - The new ICR is above MCR
        * - The adjustment won't pull the TCR below CCR
        */
        if (_isRecoveryMode) {
            _requireNoCollWithdrawal(_collWithdrawal);
            if (_isDebtIncrease) {
                _requireICRisAboveCCR(_vars.newICR);
                _requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
            }       
        } else { // if Normal Mode
            _requireICRisAboveMCR(_vars.newICR);
            _vars.newTCR = _getNewTCRFromTroveChange(_vars.collChange, _vars.isCollIncrease, _vars.netDebtChange, _isDebtIncrease, _vars.price);
            _requireNewTCRisAboveCCR(_vars.newTCR);  
        }
    }

    function _requireICRisAboveMCR(uint _newICR) internal pure {
        require(_newICR >= MCR, "ratio would fall under 110%");
    }

    function _requireICRisAboveCCR(uint _newICR) internal pure {
        require(_newICR >= CCR, "ratio must reach 150%");
    }

    function _requireNewICRisAboveOldICR(uint _newICR, uint _oldICR) internal pure {
        require(_newICR >= _oldICR, "ratio must improve in Recovery");
    }

    function _requireNewTCRisAboveCCR(uint _newTCR) internal pure {
        require(_newTCR >= CCR, "system ratio under 150%");
    }

    function _requireAtLeastMinNetDebt(uint _netDebt) internal pure {
        require (_netDebt >= MIN_NET_DEBT, "debt under the minimum");
    }

    function _requireValidLUSDRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
        require(_debtRepayment <= _currentDebt.sub(LUSD_GAS_COMPENSATION), "repaying more than the debt");
    }

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "not the Stability Pool");
    }

    function _requireCallerIsSuccessionRegistry() internal view {
        require(msg.sender == address(successionRegistry), "not the SuccessionRegistry");
    }

    // LegacyStack reduce-only state (#141): no new risk while the oracle is degraded
    function _requireOracleHealthy() internal view {
        require(!priceFeed.isReduceOnly(), "oracle degraded: reduce-only");
    }

    // LegacyStack debt ceiling (#105): $1M + $100 per $1 of wstETH in the Redemption Buffer
    function _requireUnderDebtCeiling(uint _price, uint _debtIncrease) internal view {
        require(getEntireSystemDebt().add(_debtIncrease) <= redemptionBuffer.debtCeiling(_price), "Debt ceiling reached");
    }

     function _requireSufficientLUSDBalance(ILUSDToken _lusdToken, address _borrower, uint _debtRepayment) internal view {
        require(_lusdToken.balanceOf(_borrower) >= _debtRepayment, "not enough OCT to repay");
    }

    function _requireValidMaxFeePercentage(uint _maxFeePercentage, bool _isRecoveryMode) internal pure {
        if (_isRecoveryMode) {
            require(_maxFeePercentage <= DECIMAL_PRECISION,
                "max fee above 100%");
        } else {
            require(_maxFeePercentage >= BORROWING_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
                "max fee out of range");
        }
    }

    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewNominalICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        pure
        internal
        returns (uint)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newNICR = LiquityMath._computeNominalCR(newColl, newDebt);
        return newNICR;
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        pure
        internal
        returns (uint)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newICR = LiquityMath._computeCR(newColl, newDebt, _price);
        return newICR;
    }

    function _getNewTroveAmounts(
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        pure
        returns (uint, uint)
    {
        uint newColl = _coll;
        uint newDebt = _debt;

        newColl = _isCollIncrease ? _coll.add(_collChange) :  _coll.sub(_collChange);
        newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

        return (newColl, newDebt);
    }

    function _getNewTCRFromTroveChange
    (
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        internal
        view
        returns (uint)
    {
        uint totalColl = getEntireSystemColl();
        uint totalDebt = getEntireSystemDebt();

        totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
        totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

        uint newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price);
        return newTCR;
    }

    function getCompositeDebt(uint _debt) external pure override returns (uint) {
        return _getCompositeDebt(_debt);
    }
}
