// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IPriceFeed {

    // --- Events ---
    event LastGoodPriceUpdated(uint _lastGoodPrice);

    // --- Function ---
    // Returns the price to use for the current transaction and refreshes the feed's health state.
    // Healthy: the fresh collateral price. Degraded: the last good price (reduce-only state, LegacyStack #141).
    function fetchPrice() external returns (uint);

    // LegacyStack: true while the feed is degraded. Callers that open risk (open, borrow, withdraw
    // collateral, redeem, buy buffer inventory) must refuse; repay, add collateral, close and liquidate
    // at the last good price stay open.
    function isReduceOnly() external view returns (bool);

    function lastGoodPrice() external view returns (uint);
}
