// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the Trove Manager.
interface IBorrowerOperations {

    // --- Events ---

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event LUSDTokenAddressChanged(address _lusdTokenAddress);
    event LQTYStakingAddressChanged(address _lqtyStakingAddress);

    event TroveCreated(address indexed _borrower, uint arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, uint8 operation);
    event LUSDBorrowingFeePaid(address indexed _borrower, uint _LUSDFee);
    event AutoRepaySet(address indexed _borrower, uint8 _cadence);
    event YieldSkimmed(address indexed _borrower, address indexed _caller, uint _collSold, uint _octBought, uint _repaid, uint _cut, uint _toOwner);

    // --- Functions ---

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
    ) external;

    function openTrove(uint _maxFee, uint _LUSDAmount, address _upperHint, address _lowerHint, uint _collAmount) external;

    function addColl(address _upperHint, address _lowerHint, uint _collAmount) external;

    function moveETHGainToTrove(address _user, address _upperHint, address _lowerHint, uint _collAmount) external;

    function withdrawColl(uint _amount, address _upperHint, address _lowerHint) external;

    function withdrawLUSD(uint _maxFee, uint _amount, address _upperHint, address _lowerHint) external;

    function repayLUSD(uint _amount, address _upperHint, address _lowerHint) external;

    function closeTrove() external;

    function adjustTrove(uint _maxFee, uint _collWithdrawal, uint _debtChange, bool isDebtIncrease, address _upperHint, address _lowerHint, uint _collDeposit) external;

    function claimCollateral() external;

    // LegacyStack (#161): anyone may add collateral to any active vault, from their own balance. A vault can
    // only be made safer by a third party, never riskier, and nothing a third party does counts as life.
    function addCollateralFor(address _owner, address _upperHint, address _lowerHint, uint _collAmount) external;

    // LegacyStack auto-repay from staking rewards (#160, #161). The owner opts in with a cadence: 0 off,
    // 1 monthly, 2 quarterly, 3 yearly. skimYield sells exactly the wstETH that Lido's rate growth added
    // since the vault's baseline to the reserve's standing offer and repays the vault with the OCT. The owner
    // may skim at any time with no cut; anyone else only once per cadence period, only when the yield covers
    // the period's interest, and keeps 1% of the OCT, capped at 5 OCT. The vault's stETH-denominated collateral
    // never falls below its baseline, and the ratio can only improve.
    function setAutoRepay(uint8 _cadence) external;
    function skimYield(address _owner, address _upperHint, address _lowerHint) external;
    function autoRepay(address _owner) external view returns (uint8 cadence, uint64 lastSkim, uint baseline);

    // LegacyStack succession: surplus collateral of the owner sent to the registry. Registry only.
    function claimCollateralForSuccession(address _owner, address _to) external;

    // LegacyStack succession: settle the owner's debt at par (estate OCT held by the registry, then buffer
    // inventory, then a Stability Pool offset at par), close the vault when fully settled and send the
    // remaining collateral to the registry. Registry only.
    function settleForSuccession(address _owner, uint _octAvailable) external returns (uint octUsed, bool closed, uint collReleased);

    function getCompositeDebt(uint _debt) external pure returns (uint);
}
