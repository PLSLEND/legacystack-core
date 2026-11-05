// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../upstream/Interfaces/IPriceFeed.sol";
import "../upstream/Dependencies/AggregatorV3Interface.sol";
import "../upstream/Dependencies/SafeMath.sol";
import "../upstream/Dependencies/BaseMath.sol";
import "../upstream/Dependencies/LiquityMath.sol";
import "./Interfaces/IWstETH.sol";

/*
* LegacyStack price feed (SR-1, LS_06 #98, #141).
*
* Price of one wstETH in USD = Chainlink ETH/USD  x  Lido stEthPerToken().
* No DEX read, no second market oracle, no admin, no fallback key.
*
* Breakers (any one of them puts the feed into the DEGRADED state):
*   - Chainlink call reverts, round id 0, zero or negative answer, timestamp in the future
*   - Chainlink round older than TIMEOUT
*   - Chainlink answer moved more than MAX_ROUND_DEVIATION against the previous round
*   - Lido call reverts or returns 0
*   - Lido rate moved more than the rate band against the last good rate; the band widens with the
*     time since the last good fetch so that a legitimate move heals the feed on its own
*
* DEGRADED means reduce-only for the protocol: repay, add collateral, close and liquidate at the last
* good price stay open; open, borrow, withdraw collateral, redeem and buy buffer inventory are refused.
* The feed returns to HEALTHY by itself as soon as both sources pass the checks again. No pause key.
* This replaces the upstream Chainlink/Tellor switching logic and the auto-pause of the May build.
*/
contract PriceFeed is BaseMath, IPriceFeed {
    using SafeMath for uint256;

    string constant public NAME = "PriceFeed";

    AggregatorV3Interface public immutable ethUsdAggregator;
    IWstETH public immutable wstETH;

    uint public immutable TIMEOUT;                                  // seconds; mainnet ETH/USD heartbeat is 1 h, use 4 h
    uint constant public MAX_ROUND_DEVIATION = 5e17;                // 50% between two consecutive Chainlink rounds
    uint constant public RATE_BAND = 1e16;                          // 1% Lido rate move per fetch
    uint constant public RATE_BAND_PER_DAY = 1e15;                  // +0.1% per day since the last good fetch
    uint constant public TARGET_DIGITS = 18;

    uint public override lastGoodPrice;     // wstETH/USD, 18 decimals
    uint public lastGoodEthPrice;           // ETH/USD, 18 decimals
    uint public lastGoodRate;               // stETH per wstETH, 18 decimals
    uint public lastGoodTimestamp;

    enum Status { healthy, degraded }
    Status public status;

    event PriceFeedStatusChanged(Status _newStatus);

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
        uint8 decimals;
    }

    constructor(address _ethUsdAggregator, address _wstETH, uint _timeout) public {
        require(_ethUsdAggregator != address(0) && _wstETH != address(0), "PriceFeed: zero address");
        require(_timeout >= 1 hours && _timeout <= 7 days, "PriceFeed: timeout out of range");
        ethUsdAggregator = AggregatorV3Interface(_ethUsdAggregator);
        wstETH = IWstETH(_wstETH);
        TIMEOUT = _timeout;

        // The deployment itself must see a healthy feed; there is no other way to seed the last good price.
        (uint ethPrice, bool ethOk) = _readChainlink(AggregatorV3Interface(_ethUsdAggregator), _timeout);
        (uint rate, bool rateOk) = _readRate(IWstETH(_wstETH));
        require(ethOk && rateOk, "PriceFeed: sources must be healthy at deployment");
        lastGoodEthPrice = ethPrice;
        lastGoodRate = rate;
        lastGoodPrice = ethPrice.mul(rate).div(DECIMAL_PRECISION);
        lastGoodTimestamp = block.timestamp;
        status = Status.healthy;
        emit LastGoodPriceUpdated(lastGoodPrice);
    }

    // --- IPriceFeed ---

    function fetchPrice() external override returns (uint) {
        (uint price, bool healthy) = _evaluate();
        if (healthy) {
            if (status != Status.healthy) { status = Status.healthy; emit PriceFeedStatusChanged(Status.healthy); }
            return price;
        }
        if (status != Status.degraded) { status = Status.degraded; emit PriceFeedStatusChanged(Status.degraded); }
        return lastGoodPrice;
    }

    function isReduceOnly() external view override returns (bool) {
        return status == Status.degraded;
    }

    // Same evaluation without storage writes, for frontends and quotes: (price the next fetch would use, healthy?)
    function peek() external view returns (uint price, bool healthy) {
        (uint ethPrice, bool ethOk) = _readChainlink(ethUsdAggregator, TIMEOUT);
        (uint rate, bool rateOk) = _readRate(wstETH);
        if (!ethOk || !rateOk || !_rateWithinBand(rate)) { return (lastGoodPrice, false); }
        return (ethPrice.mul(rate).div(DECIMAL_PRECISION), true);
    }

    // --- Internal ---

    function _evaluate() internal returns (uint price, bool healthy) {
        (uint ethPrice, bool ethOk) = _readChainlink(ethUsdAggregator, TIMEOUT);
        (uint rate, bool rateOk) = _readRate(wstETH);
        if (!ethOk || !rateOk || !_rateWithinBand(rate)) { return (lastGoodPrice, false); }

        price = ethPrice.mul(rate).div(DECIMAL_PRECISION);
        lastGoodEthPrice = ethPrice;
        lastGoodRate = rate;
        lastGoodPrice = price;
        lastGoodTimestamp = block.timestamp;
        emit LastGoodPriceUpdated(price);
        return (price, true);
    }

    // The Lido rate may drift by RATE_BAND plus RATE_BAND_PER_DAY for every day since the last good fetch.
    // A real move beyond the band degrades the feed for a while and then heals; it cannot lock the protocol.
    function _rateWithinBand(uint _rate) internal view returns (bool) {
        uint ref = lastGoodRate;
        if (ref == 0) { return true; }
        uint daysSince = block.timestamp.sub(lastGoodTimestamp).div(1 days);
        uint band = RATE_BAND.add(RATE_BAND_PER_DAY.mul(daysSince));
        uint diff = _rate > ref ? _rate.sub(ref) : ref.sub(_rate);
        return diff.mul(DECIMAL_PRECISION).div(ref) <= band;
    }

    function _readRate(IWstETH _wst) internal view returns (uint rate, bool ok) {
        try _wst.stEthPerToken() returns (uint256 r) {
            if (r == 0) { return (0, false); }
            return (r, true);
        } catch {
            return (0, false);
        }
    }

    function _readChainlink(AggregatorV3Interface _agg, uint _timeout) internal view returns (uint price, bool ok) {
        ChainlinkResponse memory current = _currentChainlinkResponse(_agg);
        if (!current.success || _chainlinkIsBroken(current) || _chainlinkIsFrozen(current, _timeout)) { return (0, false); }

        ChainlinkResponse memory prev = _prevChainlinkResponse(_agg, current.roundId, current.decimals);
        if (!prev.success || _chainlinkIsBroken(prev)) { return (0, false); }

        uint currentScaled = _scale(uint256(current.answer), current.decimals);
        uint prevScaled = _scale(uint256(prev.answer), prev.decimals);
        if (_deviationTooLarge(currentScaled, prevScaled)) { return (0, false); }

        return (currentScaled, true);
    }

    function _chainlinkIsBroken(ChainlinkResponse memory _r) internal view returns (bool) {
        if (_r.roundId == 0) { return true; }
        if (_r.timestamp == 0 || _r.timestamp > block.timestamp) { return true; }
        if (_r.answer <= 0) { return true; }
        return false;
    }

    function _chainlinkIsFrozen(ChainlinkResponse memory _r, uint _timeout) internal view returns (bool) {
        return block.timestamp.sub(_r.timestamp) > _timeout;
    }

    function _deviationTooLarge(uint _current, uint _prev) internal pure returns (bool) {
        uint maxPrice = LiquityMath._max(_current, _prev);
        uint minPrice = LiquityMath._min(_current, _prev);
        uint deviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);
        return deviation > MAX_ROUND_DEVIATION;
    }

    function _scale(uint _price, uint8 _decimals) internal pure returns (uint) {
        if (_decimals >= TARGET_DIGITS) {
            return _price.div(10 ** (uint(_decimals).sub(TARGET_DIGITS)));
        }
        return _price.mul(10 ** (TARGET_DIGITS.sub(uint(_decimals))));
    }

    function _currentChainlinkResponse(AggregatorV3Interface _agg) internal view returns (ChainlinkResponse memory r) {
        try _agg.decimals() returns (uint8 d) {
            r.decimals = d;
        } catch {
            return r;
        }
        try _agg.latestRoundData() returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80) {
            r.roundId = roundId;
            r.answer = answer;
            r.timestamp = updatedAt;
            r.success = true;
            return r;
        } catch {
            return r;
        }
    }

    function _prevChainlinkResponse(AggregatorV3Interface _agg, uint80 _currentRoundId, uint8 _decimals) internal view returns (ChainlinkResponse memory r) {
        if (_currentRoundId == 0) { return r; }
        try _agg.getRoundData(_currentRoundId - 1) returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80) {
            r.roundId = roundId;
            r.answer = answer;
            r.timestamp = updatedAt;
            r.success = true;
            r.decimals = _decimals;
            return r;
        } catch {
            return r;
        }
    }
}
