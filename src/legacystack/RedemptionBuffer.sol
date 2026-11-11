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
* ceiling: $1M + $100 for every $1 of wstETH in the pot. No admin.
*
* Two kinds of wstETH live in the pot. The protocol's own (fees, redemption inflows, fills: nobody has a
* claim on it) and RESERVE DEPOSITS (#160, #161): wstETH that stays the depositor's property, serves
* redemptions like the rest, is locked for 180 days from the last deposit and withdrawable afterwards
* whenever the pot stays at or above target after the withdrawal. Deposits earn time-served points
* (wstETH-seconds) that a periphery contract pays STACK emissions for; the core knows no token.
*
* Surplus waterfall (#160): measured on the protocol's own wstETH only, never on deposits: half of the
* band between 100% and 200% of target plus everything above 200%, at most 5% of the own pot per day,
* goes to the surplus sink (the burn auction and the POL keeper, periphery).
*
* Ownable is used only for the one-time setAddresses, then renounced (upstream pattern).
*/
contract RedemptionBuffer is BaseMath, Ownable, CheckContract, IRedemptionBuffer {
    using SafeMath for uint256;

    string constant public NAME = "RedemptionBuffer";

    address public troveManagerAddress;
    address public borrowerOperationsAddress;
    IPriceFeed public priceFeed;
    ILUSDToken public octToken;
    IERC20 public collateralToken;

    // Economics (LS_06 #100-#105). Not tunable after deployment.
    uint constant public TARGET_BPS = 1500;                 // pot target: 15% of circulating OCT, valued at oracle
    uint constant public FLOOR_BPS = 1000;                  // floor: 10% (reported, used by peripherals)
    uint constant public override OFFER_PREMIUM = 5e15;     // standing offer at par + 0.5%
    uint constant public CEILING_BASE = 1000000e18;       // $1M of OCT debt with an empty pot
    uint constant public CEILING_PER_USD = 100;             // + $100 of ceiling per $1 in the pot
    uint constant public RELEASE_PER_DAY_BPS = 500;         // at most 5% of the own pot per day
    uint constant public DEPOSIT_LOCK = 180 days;           // reserve deposits: lock from the last deposit
    uint constant public BPS = 10000;

    // Surplus sink: where the waterfall's releases go (a periphery splitter: burn auction + POL keeper).
    // Set once with the addresses, then immutable in effect.
    address public surplusSink;
    uint public lastRelease;

    // Reserve deposits (principal retained) and their time-served points, in wstETH-seconds
    mapping(address => uint) public override depositOf;
    mapping(address => uint) public override lockedUntil;
    uint public override totalDeposits;
    mapping(address => uint) internal points;
    mapping(address => uint) internal lastPoint;

    constructor() public {
        lastRelease = block.timestamp;
    }

    // --- Setup ---

    function setAddresses(
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _priceFeedAddress,
        address _octTokenAddress,
        address _collateralTokenAddress,
        address _surplusSink
    )
        external
        override
        onlyOwner
    {
        checkContract(_troveManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_priceFeedAddress);
        checkContract(_octTokenAddress);
        checkContract(_collateralTokenAddress);
        require(_surplusSink != address(0), "RedemptionBuffer: zero sink");

        troveManagerAddress = _troveManagerAddress;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        priceFeed = IPriceFeed(_priceFeedAddress);
        octToken = ILUSDToken(_octTokenAddress);
        collateralToken = IERC20(_collateralTokenAddress);
        surplusSink = _surplusSink;

        _renounceOwnership();
    }

    // --- Views ---

    function pot() public view override returns (uint) {
        return collateralToken.balanceOf(address(this));
    }

    function inventory() public view override returns (uint) {
        return octToken.balanceOf(address(this));
    }

    // The protocol's own wstETH: the pot minus the depositors' principal
    function ownPot() public view override returns (uint) {
        uint p = pot();
        return p > totalDeposits ? p.sub(totalDeposits) : 0;
    }

    // Time-served points of a depositor: wstETH-seconds, including the time since the last checkpoint
    function pointsOf(address _depositor) public view override returns (uint) {
        return points[_depositor].add(depositOf[_depositor].mul(block.timestamp.sub(lastPoint[_depositor])));
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

    // The standing offer values wstETH at the lower of the canonical and the market price (#162): the reserve
    // never pays more than the market for collateral.
    function offerPrice() public override returns (uint) {
        return priceFeed.lowerOfMarket(priceFeed.fetchPrice());
    }

    function buyInventory(uint _octAmount, uint _maxCollIn) external override returns (uint collIn) {
        require(_octAmount > 0, "RedemptionBuffer: zero amount");
        require(_octAmount <= inventory(), "RedemptionBuffer: not enough inventory");
        uint price = offerPrice();
        require(!priceFeed.isReduceOnly(), "RedemptionBuffer: oracle degraded, offer closed");
        collIn = quoteInventory(_octAmount, price);
        require(collIn <= _maxCollIn, "RedemptionBuffer: price above max");
        require(collateralToken.transferFrom(msg.sender, address(this), collIn), "RedemptionBuffer: collateral transferFrom failed");
        require(octToken.transfer(msg.sender, _octAmount), "RedemptionBuffer: OCT transfer failed");
        emit InventorySold(msg.sender, _octAmount, collIn);
    }

    function serveSkim(address _owner, uint _octAmount, uint _collIn, address _cutTo, uint _cut, uint _rest) external override {
        require(msg.sender == borrowerOperationsAddress, "RedemptionBuffer: caller is not BorrowerOperations");
        require(_octAmount > 0 && _octAmount <= inventory(), "RedemptionBuffer: not enough inventory");
        require(_cut.add(_rest) <= _octAmount, "RedemptionBuffer: split exceeds the sale");
        uint price = offerPrice();
        require(!priceFeed.isReduceOnly(), "RedemptionBuffer: oracle degraded, offer closed");
        require(_collIn >= quoteInventory(_octAmount, price), "RedemptionBuffer: below the standing offer");
        if (_cut > 0) { require(octToken.transfer(_cutTo, _cut), "RedemptionBuffer: OCT transfer failed"); }
        if (_rest > 0) { require(octToken.transfer(_owner, _rest), "RedemptionBuffer: OCT transfer failed"); }
        emit SkimServed(_owner, _octAmount, _collIn, _cut, _rest);
    }

    function fill(uint _collAmount) external override {
        require(_collAmount > 0, "RedemptionBuffer: zero amount");
        require(collateralToken.transferFrom(msg.sender, address(this), _collAmount), "RedemptionBuffer: collateral transferFrom failed");
        emit Filled(msg.sender, _collAmount);
    }

    // --- Reserve deposits ---

    function deposit(uint _collAmount) external override {
        require(_collAmount > 0, "RedemptionBuffer: zero amount");
        _checkpoint(msg.sender);
        require(collateralToken.transferFrom(msg.sender, address(this), _collAmount), "RedemptionBuffer: collateral transferFrom failed");
        depositOf[msg.sender] = depositOf[msg.sender].add(_collAmount);
        totalDeposits = totalDeposits.add(_collAmount);
        lockedUntil[msg.sender] = block.timestamp.add(DEPOSIT_LOCK);
        emit Deposited(msg.sender, _collAmount, lockedUntil[msg.sender]);
    }

    function withdraw(uint _collAmount) external override {
        require(_collAmount > 0, "RedemptionBuffer: zero amount");
        require(block.timestamp >= lockedUntil[msg.sender], "RedemptionBuffer: deposit still locked");
        require(_collAmount <= depositOf[msg.sender], "RedemptionBuffer: more than deposited");
        uint price = priceFeed.fetchPrice();
        uint valueAfter = pot().sub(_collAmount).mul(price).div(DECIMAL_PRECISION);
        require(valueAfter >= target(), "RedemptionBuffer: the pot would fall below target");
        _checkpoint(msg.sender);
        depositOf[msg.sender] = depositOf[msg.sender].sub(_collAmount);
        totalDeposits = totalDeposits.sub(_collAmount);
        require(collateralToken.transfer(msg.sender, _collAmount), "RedemptionBuffer: collateral transfer failed");
        emit Withdrawn(msg.sender, _collAmount);
    }

    // Anyone may write a depositor's points to storage (the emissions contract does before it pays).
    function checkpoint(address _depositor) external override {
        _checkpoint(_depositor);
    }

    function _checkpoint(address _depositor) internal {
        points[_depositor] = pointsOf(_depositor);
        lastPoint[_depositor] = block.timestamp;
    }

    // --- Surplus waterfall ---

    // What the waterfall could release right now, in wstETH, before the daily cap: on the protocol's own
    // pot, half of the band between 100% and 200% of target plus everything above 200%.
    function releasable(uint _price) public view override returns (uint) {
        uint value = ownPot().mul(_price).div(DECIMAL_PRECISION);
        uint tgt = target();
        if (value <= tgt) { return 0; }
        uint twice = tgt.mul(2);
        uint band = LiquityMath._min(value, twice).sub(tgt);
        uint above = value > twice ? value.sub(twice) : 0;
        return band.div(2).add(above).mul(DECIMAL_PRECISION).div(_price);
    }

    function releaseSurplus() external override returns (uint) {
        uint price = priceFeed.fetchPrice();
        require(!priceFeed.isReduceOnly(), "RedemptionBuffer: oracle degraded");
        require(block.timestamp.sub(lastRelease) >= 1 days, "RedemptionBuffer: one release per day");
        uint amount = LiquityMath._min(releasable(price), ownPot().mul(RELEASE_PER_DAY_BPS).div(BPS));
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
