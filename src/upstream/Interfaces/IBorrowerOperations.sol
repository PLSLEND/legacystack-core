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

    // LegacyStack operator role (#129): an operator named by the owner adjusts the owner's vault. Deposits and
    // repayments come from the operator; borrowed OCT and withdrawn collateral always go to the owner.
    function operatorAdjustTrove(address _owner, uint _maxFee, uint _collWithdrawal, uint _debtChange, bool isDebtIncrease, address _upperHint, address _lowerHint, uint _collDeposit) external;

    // LegacyStack succession: surplus collateral of the owner sent to the registry. Registry only.
    function claimCollateralForSuccession(address _owner, address _to) external;

    // LegacyStack succession: settle the owner's debt at par (estate OCT held by the registry, then buffer
    // inventory, then a Stability Pool offset at par), close the vault when fully settled and send the
    // remaining collateral to the registry. Registry only.
    function settleForSuccession(address _owner, uint _octAvailable) external returns (uint octUsed, bool closed, uint collReleased);

    function getCompositeDebt(uint _debt) external pure returns (uint);
}
