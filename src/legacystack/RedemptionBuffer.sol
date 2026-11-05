// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IRedemptionBuffer.sol";
import "../upstream/Interfaces/IPriceFeed.sol";
import "../upstream/Interfaces/ILUSDToken.sol";
import "../upstream/Dependencies/IERC20.sol";
import "../upstream/Dependencies/SafeMath.sol";
import "../upstream/Dependencies/BaseMath.sol";
import "../upstream/Dependencies/Ownable.sol";
import "../upstream/Dependencies/CheckContract.sol";
import "../upstream/Dependencies/LiquityMath.sol";

/*
* Redemption Buffer (LegacyStack LS_06 #100-#105, LS_22 rows 5-7).
*
* Holds wstETH (the pot) and OCT (the inventory). Serves redemptions before any user vault is touched,
* receives every fee and all interest, sells inventory at oracle par + premium, and sets the debt
* ceiling: $1M + $100 for every $1 of wstETH in the pot. Nobody can withdraw from it. No admin.
*
* Ownable is used only for the one-time setAddresses, then renounced (upstream pattern).
*/
contract RedemptionBuffer is BaseMath, Ownable, CheckContract, IRedemptionBuffer {
    using SafeMath for uint256;

    string constant public NAME = "RedemptionBuffer";

    address public troveManagerAddress;
    IPriceFeed public priceFeed;
    ILUSDToken public octToken;
    IERC20 public collateralToken;

    // Economics (LS_06 #100-#105). Not tunable after deployment.
    uint constant public TARGET_BPS = 1500;                 // pot target: 15% of circulating OCT, valued at oracle
    uint constant public FLOOR_BPS = 1000;                  // floor: 10% (reported, used by peripherals)
    uint constant public OFFER_PREMIUM = 5e15;              // standing offer at par + 0.5%
    uint constant public CEILING_BASE = 1000000e18;       // $1M of OCT debt with an empty pot
    uint constant public CEILING_PER_USD = 100;             // + $100 of ceiling per $1 in the pot
    uint constant public RELEASE_THRESHOLD_BPS = 20000;     // release surplus only above 200% of target
    uint constant public RELEASE_PER_DAY_BPS = 500;         // at most 5% of the pot per day
    uint constant public BPS = 10000;

    // Surplus sink: where releases above 200% of target go (LS_22 row 7: 40 LP / 20 SP / 40 STACK burn
    // splitter, a peripheral). Fixed at deployment. For the testnet this is a plain address.
    address public immutable surplusSink;
    uint public lastRelease;

    constructor(address _surplusSink) public {
        require(_surplusSink != address(0), "RedemptionBuffer: zero sink");
        surplusSink = _surplusSink;
        lastRelease = block.timestamp;
    }

    // --- Setup ---

    function setAddresses(
        address _troveManagerAddress,
        address _priceFeedAddress,
        address _octTokenAddress,
        address _collateralTokenAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_troveManagerAddress);
        checkContract(_priceFeedAddress);
        checkContract(_octTokenAddress);
        checkContract(_collateralTokenAddress);

        troveManagerAddress = _troveManagerAddress;
        priceFeed = IPriceFeed(_priceFeedAddress);
        octToken = ILUSDToken(_octTokenAddress);
        collateralToken = IERC20(_collateralTokenAddress);

        _renounceOwnership();
    }

    // --- Views ---

    function pot() public view override returns (uint) {
        return collateralToken.balanceOf(address(this));
    }

    function inventory() public view override returns (uint) {
        return octToken.balanceOf(address(this));
    }

    function potValue(uint _price) public view override returns (uint) {
        return pot().mul(_price).div(DECIMAL_PRECISION);
    }

    function circulatingSupply() public view override returns (uint) {
        uint supply = octToken.totalSupply();
        uint inv = inventory();
        return supply > inv ? supply.sub(inv) : 0;
    }

    function target() public view override returns (uint) {
        return circulatingSupply().mul(TARGET_BPS).div(BPS);
    }

    // OCT the buffer can absorb right now: every unit of pot value at the oracle price. The fee stays in the pot.
    function redeemCapacity(uint _price) public view override returns (uint) {
        return potValue(_price);
    }

    function debtCeiling(uint _price) external view override returns (uint) {
        return CEILING_BASE.add(potValue(_price).mul(CEILING_PER_USD));
    }

    function quoteInventory(uint _octAmount, uint _price) public view override returns (uint collIn) {
        require(_price > 0, "RedemptionBuffer: zero price");
        // collIn = oct * (1 + premium) / price, rounded up in the buffer's favour
        uint numerator = _octAmount.mul(DECIMAL_PRECISION.add(OFFER_PREMIUM));
        collIn = numerator.div(_price);
        if (collIn.mul(_price) < numerator) { collIn = collIn.add(1); }
    }

    // --- Actions ---

    function serveRedemption(address _redeemer, uint _octAmount, uint _price, uint _redemptionRate) external override returns (uint) {
        _requireCallerIsTroveManager();
        require(_octAmount > 0, "RedemptionBuffer: zero amount");
        uint collDrawn = _octAmount.mul(DECIMAL_PRECISION).div(_price);
        require(collDrawn <= pot(), "RedemptionBuffer: beyond capacity");
        uint fee = collDrawn.mul(_redemptionRate).div(DECIMAL_PRECISION);
        require(fee < collDrawn, "RedemptionBuffer: fee would eat the collateral");
        uint collOut = collDrawn.sub(fee);
        require(collateralToken.transfer(_redeemer, collOut), "RedemptionBuffer: collateral transfer failed");
        emit RedemptionServed(_redeemer, _octAmount, collOut, fee);
        return collOut;
    }

    function buyInventory(uint _octAmount, uint _maxCollIn) external override returns (uint collIn) {
        require(_octAmount > 0, "RedemptionBuffer: zero amount");
        require(_octAmount <= inventory(), "RedemptionBuffer: not enough inventory");
        uint price = priceFeed.fetchPrice();
        require(!priceFeed.isReduceOnly(), "RedemptionBuffer: oracle degraded, offer closed");
        collIn = quoteInventory(_octAmount, price);
        require(collIn <= _maxCollIn, "RedemptionBuffer: price above max");
        require(collateralToken.transferFrom(msg.sender, address(this), collIn), "RedemptionBuffer: collateral transferFrom failed");
        require(octToken.transfer(msg.sender, _octAmount), "RedemptionBuffer: OCT transfer failed");
        emit InventorySold(msg.sender, _octAmount, collIn);
    }

    function fill(uint _collAmount) external override {
        require(_collAmount > 0, "RedemptionBuffer: zero amount");
        require(collateralToken.transferFrom(msg.sender, address(this), _collAmount), "RedemptionBuffer: collateral transferFrom failed");
        emit Filled(msg.sender, _collAmount);
    }

    function releaseSurplus() external override returns (uint) {
        uint price = priceFeed.fetchPrice();
        require(!priceFeed.isReduceOnly(), "RedemptionBuffer: oracle degraded");
        uint currentPot = pot();
        uint value = currentPot.mul(price).div(DECIMAL_PRECISION);
        uint threshold = target().mul(RELEASE_THRESHOLD_BPS).div(BPS);
        require(value > threshold, "RedemptionBuffer: pot not above release threshold");

        uint excessValue = value.sub(threshold);
        uint excessColl = excessValue.mul(DECIMAL_PRECISION).div(price);
        uint daysSince = block.timestamp.sub(lastRelease).div(1 days);
        require(daysSince >= 1, "RedemptionBuffer: one release per day");
        uint dailyCap = currentPot.mul(RELEASE_PER_DAY_BPS).div(BPS);
        uint amount = LiquityMath._min(excessColl, dailyCap);
        require(amount > 0, "RedemptionBuffer: nothing to release");

        lastRelease = block.timestamp;
        require(collateralToken.transfer(surplusSink, amount), "RedemptionBuffer: collateral transfer failed");
        emit SurplusReleased(surplusSink, amount);
        return amount;
    }

    // --- Require ---

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "RedemptionBuffer: caller is not TroveManager");
    }
}
