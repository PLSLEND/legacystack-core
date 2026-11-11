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

    // LegacyStack #160: the permanent end state (every ETH/USD source dead for 30 days). Reduce-only forever;
    // succession settles at the last good price with a haircut applied by BorrowerOperations.
    function isWindDown() external view returns (bool);

    // LegacyStack #162: the lower of the canonical price and the stETH/USD market price times the rate, for
    // the paths where the protocol pays for collateral (new borrowing, withdrawals, the standing offer).
    function lowerOfMarket(uint _canonical) external view returns (uint);

    function lastGoodPrice() external view returns (uint);
}
