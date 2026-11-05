// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IDefaultPool.sol';
import './Interfaces/ITroveManager.sol';
import './Dependencies/IERC20.sol';
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
 * The Default Pool holds the ETH and LUSD debt (but not LUSD tokens) from liquidations that have been redistributed
 * to active troves but not yet "applied", i.e. not yet recorded on a recipient active trove's struct.
 *
 * When a trove makes an operation that applies its pending ETH and LUSD debt, its pending ETH and LUSD debt is moved
 * from the Default Pool to the Active Pool.
 */
contract DefaultPool is Ownable, CheckContract, IDefaultPool {
    using SafeMath for uint256;

    string constant public NAME = "DefaultPool";

    address public troveManagerAddress;
    address public activePoolAddress;
    IERC20 public collateralToken; // LegacyStack: wstETH
    uint256 internal ETH;  // deposited ETH tracker
    uint256 internal LUSDDebt;  // debt, LegacyStack: NORMALIZED units
    uint constant internal DECIMAL_PRECISION = 1e18;

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolLUSDDebtUpdated(uint _LUSDDebt);
    event DefaultPoolETHBalanceUpdated(uint _ETH);

    // --- Dependency setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _collateralTokenAddress
    )
        external
        onlyOwner
    {
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_collateralTokenAddress);

        troveManagerAddress = _troveManagerAddress;
        activePoolAddress = _activePoolAddress;
        collateralToken = IERC20(_collateralTokenAddress);

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
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

    function sendETHToActivePool(uint _amount) external override {
        _requireCallerIsTroveManager();
        address activePool = activePoolAddress; // cache to save an SLOAD
        ETH = ETH.sub(_amount);
        emit DefaultPoolETHBalanceUpdated(ETH);
        emit EtherSent(activePool, _amount);

        require(collateralToken.transfer(activePool, _amount), "DefaultPool: collateral transfer failed");
        IPool(activePool).receiveCollateral(_amount);
    }

    // LegacyStack: called by ActivePool after transferring collateral tokens here
    function receiveCollateral(uint _amount) external override {
        _requireCallerIsActivePool();
        ETH = ETH.add(_amount);
        emit DefaultPoolETHBalanceUpdated(ETH);
    }

    // _amount in ACTUAL units; rounds down
    function increaseLUSDDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        uint idx = ITroveManager(troveManagerAddress).currentRateIndex();
        LUSDDebt = LUSDDebt.add(_amount.mul(DECIMAL_PRECISION).div(idx));
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    // _amount in ACTUAL units; rounds up
    function decreaseLUSDDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        uint idx = ITroveManager(troveManagerAddress).currentRateIndex();
        uint numerator = _amount.mul(DECIMAL_PRECISION);
        uint n = numerator.div(idx);
        if (n.mul(idx) < numerator) { n = n.add(1); }
        LUSDDebt = n >= LUSDDebt ? 0 : LUSDDebt.sub(n);
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    function increaseNormalizedDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = LUSDDebt.add(_amount);
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    function decreaseNormalizedDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = _amount >= LUSDDebt ? 0 : LUSDDebt.sub(_amount);
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "DefaultPool: Caller is not the TroveManager");
    }

}
