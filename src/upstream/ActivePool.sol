// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IActivePool.sol';
import './Interfaces/ITroveManager.sol';
import './Dependencies/IERC20.sol';
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
 * The Active Pool holds the ETH collateral and LUSD debt (but not LUSD tokens) for all active troves.
 *
 * When a trove is liquidated, it's ETH and LUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is Ownable, CheckContract, IActivePool {
    using SafeMath for uint256;

    string constant public NAME = "ActivePool";

    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public stabilityPoolAddress;
    address public defaultPoolAddress;
    address public collSurplusPoolAddress;
    IERC20 public collateralToken; // LegacyStack: wstETH
    uint256 internal ETH;  // deposited ether tracker
    uint256 internal LUSDDebt;  // LegacyStack: NORMALIZED units
    uint constant internal DECIMAL_PRECISION = 1e18;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolLUSDDebtUpdated(uint _LUSDDebt);
    event ActivePoolETHBalanceUpdated(uint _ETH);

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _collSurplusPoolAddress,
        address _collateralTokenAddress
    )
        external
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_collateralTokenAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;
        collateralToken = IERC20(_collateralTokenAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    *Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH() external view override returns (uint) {
        return ETH;
    }

    // ACTUAL units (LegacyStack)
    function getLUSDDebt() external view override returns (uint) {
        return LUSDDebt.mul(ITroveManager(troveManagerAddress).currentRateIndex()).div(DECIMAL_PRECISION);
    }

    function getNormalizedDebt() external view override returns (uint) {
        return LUSDDebt;
    }

    // --- Pool functionality ---

    function sendETH(address _account, uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        ETH = ETH.sub(_amount);
        emit ActivePoolETHBalanceUpdated(ETH);
        emit EtherSent(_account, _amount);

        require(collateralToken.transfer(_account, _amount), "ActivePool: collateral transfer failed");
        if (_account == defaultPoolAddress || _account == stabilityPoolAddress || _account == collSurplusPoolAddress) {
            IPool(_account).receiveCollateral(_amount);
        }
    }

    // LegacyStack: called by BorrowerOperations or DefaultPool after transferring collateral tokens here
    function receiveCollateral(uint _amount) external override {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        ETH = ETH.add(_amount);
        emit ActivePoolETHBalanceUpdated(ETH);
    }

    // _amount in ACTUAL units; rounds down (debt never exceeds supply)
    function increaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        uint idx = ITroveManager(troveManagerAddress).currentRateIndex();
        LUSDDebt  = LUSDDebt.add(_amount.mul(DECIMAL_PRECISION).div(idx));
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    // _amount in ACTUAL units; rounds up (debt never exceeds supply)
    function decreaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        uint idx = ITroveManager(troveManagerAddress).currentRateIndex();
        uint numerator = _amount.mul(DECIMAL_PRECISION);
        uint n = numerator.div(idx);
        if (n.mul(idx) < numerator) { n = n.add(1); }
        LUSDDebt = n >= LUSDDebt ? 0 : LUSDDebt.sub(n);
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    function increaseNormalizedDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = LUSDDebt.add(_amount);
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    function decreaseNormalizedDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = _amount >= LUSDDebt ? 0 : LUSDDebt.sub(_amount);
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "ActivePool: Caller is not TroveManager");
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager");
    }

}
