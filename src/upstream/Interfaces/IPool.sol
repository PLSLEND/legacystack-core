// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the Pools.
interface IPool {
    
    // --- Events ---
    
    event ETHBalanceUpdated(uint _newBalance);
    event LUSDBalanceUpdated(uint _newBalance);
    event ActivePoolAddressChanged(address _newActivePoolAddress);
    event DefaultPoolAddressChanged(address _newDefaultPoolAddress);
    event StabilityPoolAddressChanged(address _newStabilityPoolAddress);
    event EtherSent(address _to, uint _amount);

    // --- Functions ---
    
    function getETH() external view returns (uint);

    // LegacyStack: collateral is an ERC-20 (wstETH); pools are notified of incoming transfers
    function receiveCollateral(uint _amount) external;

    function getLUSDDebt() external view returns (uint);

    function increaseLUSDDebt(uint _amount) external;

    function decreaseLUSDDebt(uint _amount) external;

    // LegacyStack: debt is stored normalized (actual = normalized * TroveManager.currentRateIndex() / 1e18)
    function getNormalizedDebt() external view returns (uint);

    function increaseNormalizedDebt(uint _amount) external;

    function decreaseNormalizedDebt(uint _amount) external;
}
