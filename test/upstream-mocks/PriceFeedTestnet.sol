// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../../src/upstream/Interfaces/IPriceFeed.sol";

/*
* PriceFeed placeholder for tests and local development. The price is set manually. LegacyStack adds a
* manual reduce-only switch so tests can exercise the degraded-oracle paths.
*/
contract PriceFeedTestnet is IPriceFeed {

    uint256 private _price = 200 * 1e18;
    bool private _reduceOnly;

    function getPrice() external view returns (uint256) {
        return _price;
    }

    function lastGoodPrice() external view override returns (uint256) {
        return _price;
    }

    function fetchPrice() external override returns (uint256) {
        emit LastGoodPriceUpdated(_price);
        return _price;
    }

    function isReduceOnly() external view override returns (bool) {
        return _reduceOnly;
    }

    // the real PriceFeed's read-only view, used by the frontend and the Keeper desk
    function peek() external view returns (uint256 price, bool healthy) {
        return (_price, !_reduceOnly);
    }

    function setPrice(uint256 price) external returns (bool) {
        _price = price;
        return true;
    }

    function setReduceOnly(bool reduceOnly) external {
        _reduceOnly = reduceOnly;
    }
}
