// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../../src/upstream/Interfaces/IPriceFeed.sol";

/*
* PriceFeed placeholder for tests and local development. The price is set manually. LegacyStack adds a
* manual reduce-only switch so tests can exercise the degraded-oracle paths.
*/
contract PriceFeedTestnet is IPriceFeed {

    uint256 private _price = 200 * 1e18;
    uint256 private _market;        // 0: no market feed
    bool private _reduceOnly;
    bool private _windDown;

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
        return _reduceOnly || _windDown;
    }

    function isWindDown() external view override returns (bool) {
        return _windDown;
    }

    function lowerOfMarket(uint256 _canonical) external view override returns (uint256) {
        return _market != 0 && _market < _canonical ? _market : _canonical;
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

    function setMarketPrice(uint256 market) external {
        _market = market;
    }

    function setWindDown(bool windDown) external {
        _windDown = windDown;
    }
}
