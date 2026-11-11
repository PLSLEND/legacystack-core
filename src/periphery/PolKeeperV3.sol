// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Protocol-owned-liquidity keeper, Uniswap v3 flavour (LS_06 #161, #165). TESTNET STAND-IN: on Ethereum the
* venue is a Curve StableSwap-NG OCT/USDe pool and this keeper is replaced by a Curve flavour with the same
* contract shape; the rule is the venue-independent part.
*
* The rule: the wstETH the splitter sends here is turned into OCT through the reserve's standing offer (an
* internal price, no DEX read; the wstETH goes back into the reserve, the reserve's OCT inventory becomes the
* liquidity) and deposited ONE-SIDED into the pool, only when the pool's time-weighted price has OCT at or
* above par. Adding OCT when it trades at a premium nudges it back to par; adding it below par would push it
* further down, so the keeper simply waits. The position is held forever: never withdrawn, fees compound
* into depth. If the pool step fails for any reason, the whole conversion is undone and the wstETH goes to
* the burn auction instead, so a dead venue can never trap funds. Permissionless; no owner; no parameter
* after deployment.
*/
interface IPolERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); function approve(address, uint) external returns (bool); }
interface IPolBuffer {
    function inventory() external view returns (uint);
    function OFFER_PREMIUM() external view returns (uint);
    function quoteInventory(uint octAmount, uint price) external view returns (uint collIn);
    function buyInventory(uint octAmount, uint maxCollIn) external returns (uint collIn);
}
interface IPolPriceFeed { function fetchPrice() external returns (uint); }
interface IPolAuction { function notify() external; }
interface IPolPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function increaseObservationCardinalityNext(uint16) external;
}
interface IPolNPM {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    function mint(MintParams calldata params) external payable returns (uint tokenId, uint128 liquidity, uint amount0, uint amount1);
}

contract PolKeeperV3 {
    IPolERC20 public immutable collateralToken;
    IPolERC20 public immutable octToken;
    IPolBuffer public immutable reserve;
    IPolPriceFeed public immutable priceFeed;
    IPolPool public immutable pool;
    IPolNPM public immutable positionManager;
    address public immutable burnAuction;
    bool public immutable octIsToken0;
    uint32 public constant TWAP_WINDOW = 1 hours;
    int24 public constant RANGE_TICKS = 100;        // the one-sided band: ~1% wide, just beside the price

    uint public totalOctDeposited;
    uint public totalCollConverted;
    uint public totalCollToAuction;
    uint[] public positions;                        // NFT ids held forever

    event Deposited(uint tokenId, uint octIn, uint collConverted, int24 tickLower, int24 tickUpper);
    event RoutedToAuction(uint collAmount, string reason);

    constructor(address _collateralToken, address _octToken, address _reserve, address _priceFeed, address _pool, address _positionManager, address _burnAuction) {
        collateralToken = IPolERC20(_collateralToken);
        octToken = IPolERC20(_octToken);
        reserve = IPolBuffer(_reserve);
        priceFeed = IPolPriceFeed(_priceFeed);
        pool = IPolPool(_pool);
        positionManager = IPolNPM(_positionManager);
        burnAuction = _burnAuction;
        octIsToken0 = IPolPool(_pool).token0() == _octToken;
        require(octIsToken0 || IPolPool(_pool).token1() == _octToken, "PolKeeperV3: OCT is not in the pool");
        try IPolPool(_pool).increaseObservationCardinalityNext(60) {} catch {}
    }

    function positionCount() external view returns (uint) { return positions.length; }

    /// The pool's hour-long time-weighted tick (spot if the pool is too young to have the history)
    function twapTick() public view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW; ago[1] = 0;
        try pool.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int24 avg = int24(delta / int56(uint56(TWAP_WINDOW)));
            if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) avg--;
            return avg;
        } catch {
            (, int24 tick,,,,,) = pool.slot0();
            return tick;
        }
    }

    /// OCT at or above par in the pool: tick >= 0 when OCT is token0 (price = token1 per token0), else <= 0
    function octAtOrAbovePar() public view returns (bool) {
        int24 t = twapTick();
        return octIsToken0 ? t >= 0 : t <= 0;
    }

    /// Anyone: do the keeper's work with everything it holds.
    function work() external returns (uint octDeposited) {
        uint balance = collateralToken.balanceOf(address(this));
        require(balance > 0, "PolKeeperV3: nothing to deploy");
        require(octAtOrAbovePar(), "PolKeeperV3: OCT below par, waiting");
        try this.convertAndDeposit(balance) returns (uint oct) {
            octDeposited = oct;
        } catch Error(string memory reason) {
            _toAuction(balance, reason);
        } catch {
            _toAuction(balance, "pool call failed");
        }
    }

    /// Internal step exposed only to itself so that a failure anywhere inside undoes the conversion.
    function convertAndDeposit(uint _collAmount) external returns (uint oct) {
        require(msg.sender == address(this), "PolKeeperV3: internal");
        uint price = priceFeed.fetchPrice();
        oct = _collAmount * price / (1e18 + reserve.OFFER_PREMIUM());
        uint inventory = reserve.inventory();
        if (oct > inventory) oct = inventory;
        require(oct > 0, "no inventory");
        uint collIn = reserve.quoteInventory(oct, price);
        require(collateralToken.approve(address(reserve), collIn), "approve");
        reserve.buyInventory(oct, collIn);

        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 lower; int24 upper;
        if (octIsToken0) { lower = _ceil(tick + 1, spacing); upper = lower + RANGE_TICKS; }   // entirely above the price: token0 only
        else { upper = _floor(tick, spacing); lower = upper - RANGE_TICKS; }               // entirely below the price: token1 only
        require(octToken.approve(address(positionManager), oct), "approve");
        (uint tokenId,,,) = positionManager.mint(IPolNPM.MintParams({
            token0: pool.token0(), token1: pool.token1(), fee: pool.fee(), tickLower: lower, tickUpper: upper,
            amount0Desired: octIsToken0 ? oct : 0, amount1Desired: octIsToken0 ? 0 : oct,
            amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
        }));
        positions.push(tokenId);
        totalOctDeposited += oct;
        totalCollConverted += collIn;
        emit Deposited(tokenId, oct, collIn, lower, upper);
    }

    function _toAuction(uint _amount, string memory _reason) internal {
        require(collateralToken.transfer(burnAuction, _amount), "PolKeeperV3: transfer failed");
        totalCollToAuction += _amount;
        IPolAuction(burnAuction).notify();
        emit RoutedToAuction(_amount, _reason);
    }

    function _floor(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 r = _tick / _spacing * _spacing;
        if (_tick < 0 && _tick % _spacing != 0) r -= _spacing;
        return r;
    }

    function _ceil(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 f = _floor(_tick, _spacing);
        return f == _tick ? f : f + _spacing;
    }

    /// The position manager hands the NFT over with a safeTransfer check; accept it.
    function onERC721Received(address, address, uint, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
