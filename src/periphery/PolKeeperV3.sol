// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Protocol-owned-liquidity keeper, Uniswap v3 flavour (LS_06 #161, #165, #169). TESTNET STAND-IN: on Ethereum
* the venue is a Curve StableSwap-NG OCT/USDe pool and this keeper is replaced by a Curve flavour with the same
* contract shape; the rule is the venue-independent part.
*
* The rule: the wstETH the splitter sends here is turned into OCT through the reserve's standing offer (an
* internal price, no DEX read; the wstETH goes back into the reserve, the reserve's OCT inventory becomes the
* liquidity) and deposited ONE-SIDED into the pool, only when the pool's time-weighted price has OCT at or
* above par. Adding OCT when it trades at a premium nudges it back to par; adding it below par would push it
* further down, so the keeper simply waits. The position is held forever: never withdrawn.
*
* Fees (#169): `harvest()` collects what the positions earned. OCT fees go to the reserve's inventory. Fees in
* the counter-asset are turned into OCT inside the pool, only while OCT trades at or below par and never above
* 1% over it (a bid that can only help the peg), and go to the reserve too; otherwise they wait here.
*
* Failure (#169): if the pool step fails, the whole conversion is undone and the wstETH stays here for the
* next run; only after 90 days of failing does it go back to the reserve pot, so a dead venue can never trap
* funds and nothing is ever thrown away. Permissionless; no owner; no parameter after deployment.
*/
interface IPolERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); function approve(address, uint) external returns (bool); }
interface IPolBuffer {
    function inventory() external view returns (uint);
    function OFFER_PREMIUM() external view returns (uint);
    function quoteInventory(uint octAmount, uint price) external view returns (uint collIn);
    function buyInventory(uint octAmount, uint maxCollIn) external returns (uint collIn);
    function fill(uint collAmount) external;
}
interface IPolPriceFeed { function fetchPrice() external returns (uint); }
interface IPolPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function increaseObservationCardinalityNext(uint16) external;
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) external returns (int256 amount0, int256 amount1);
}
interface IPolNPM {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    struct CollectParams { uint tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata params) external payable returns (uint tokenId, uint128 liquidity, uint amount0, uint amount1);
    function collect(CollectParams calldata params) external payable returns (uint amount0, uint amount1);
}

contract PolKeeperV3 {
    IPolERC20 public immutable collateralToken;
    IPolERC20 public immutable octToken;
    IPolERC20 public immutable counterToken;     // the pool's other token (USDe on the testnet)
    IPolBuffer public immutable reserve;
    IPolPriceFeed public immutable priceFeed;
    IPolPool public immutable pool;
    IPolNPM public immutable positionManager;
    bool public immutable octIsToken0;
    uint32 public constant TWAP_WINDOW = 1 hours;
    int24 public constant RANGE_TICKS = 100;        // the one-sided band: ~1% wide, just beside the price
    uint public constant RETRY_WINDOW = 90 days;    // a venue that fails this long gives the wstETH back to the reserve
    // sqrt prices at ticks +100 and -100: the harvest never buys OCT more than 1% over par
    uint160 internal constant SQRT_TICK_PLUS_100 = 79625275426524748796330556127;
    uint160 internal constant SQRT_TICK_MINUS_100 = 78833030112140176575862854578;

    uint public totalOctDeposited;
    uint public totalCollConverted;
    uint public totalCollReturned;                  // wstETH returned to the reserve after a dead spell
    uint public totalOctHarvested;                  // OCT fees sent to the reserve (fees collected plus fees bought)
    uint public totalCounterHarvested;              // counter-asset fees collected
    uint64 public failedSince;                      // first failed run of the current dead spell, 0 when healthy
    uint[] public positions;                        // NFT ids held forever

    event Deposited(uint tokenId, uint octIn, uint collConverted, int24 tickLower, int24 tickUpper);
    event Failed(uint collAmount, string reason);
    event ReturnedToReserve(uint collAmount);
    event Harvested(uint octCollected, uint counterCollected, uint counterSold, uint octBought, uint octToReserve);

    constructor(address _collateralToken, address _octToken, address _reserve, address _priceFeed, address _pool, address _positionManager) {
        collateralToken = IPolERC20(_collateralToken);
        octToken = IPolERC20(_octToken);
        reserve = IPolBuffer(_reserve);
        priceFeed = IPolPriceFeed(_priceFeed);
        pool = IPolPool(_pool);
        positionManager = IPolNPM(_positionManager);
        address t0 = IPolPool(_pool).token0(); address t1 = IPolPool(_pool).token1();
        octIsToken0 = t0 == _octToken;
        require(octIsToken0 || t1 == _octToken, "PolKeeperV3: OCT is not in the pool");
        counterToken = IPolERC20(octIsToken0 ? t1 : t0);
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

    function octAtOrBelowPar() public view returns (bool) {
        int24 t = twapTick();
        return octIsToken0 ? t <= 0 : t >= 0;
    }

    /// Anyone: do the keeper's work with everything it holds.
    function work() external returns (uint octDeposited) {
        uint balance = collateralToken.balanceOf(address(this));
        require(balance > 0, "PolKeeperV3: nothing to deploy");
        require(octAtOrAbovePar(), "PolKeeperV3: OCT below par, waiting");
        try this.convertAndDeposit(balance) returns (uint oct) {
            octDeposited = oct;
            failedSince = 0;
        } catch Error(string memory reason) {
            _failed(balance, reason);
        } catch {
            _failed(balance, "pool call failed");
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

    /// Anyone: collect the fees the positions earned and hand them to the reserve as OCT.
    function harvest() external returns (uint octToReserve) {
        uint octCollected; uint counterCollected;
        for (uint i = 0; i < positions.length; i++) {
            (uint a0, uint a1) = positionManager.collect(IPolNPM.CollectParams({
                tokenId: positions[i], recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            }));
            octCollected += octIsToken0 ? a0 : a1;
            counterCollected += octIsToken0 ? a1 : a0;
        }
        totalCounterHarvested += counterCollected;
        // the counter-asset (this harvest's and any that waited) buys OCT in the pool, only at or below par
        uint counter = counterToken.balanceOf(address(this));
        uint counterSold; uint octBought;
        if (counter > 0 && octAtOrBelowPar()) {
            try this.buyOct(counter) returns (uint sold, uint bought) { counterSold = sold; octBought = bought; } catch {}
        }
        octToReserve = octToken.balanceOf(address(this));
        if (octToReserve > 0) {
            require(octToken.transfer(address(reserve), octToReserve), "PolKeeperV3: transfer failed");
            totalOctHarvested += octToReserve;
        }
        emit Harvested(octCollected, counterCollected, counterSold, octBought, octToReserve);
    }

    /// Internal step exposed only to itself: sell the counter-asset for OCT, never paying more than 1% over par.
    function buyOct(uint _amount) external returns (uint sold, uint bought) {
        require(msg.sender == address(this), "PolKeeperV3: internal");
        bool zeroForOne = !octIsToken0;                                  // we sell the counter token
        uint160 limit = octIsToken0 ? SQRT_TICK_PLUS_100 : SQRT_TICK_MINUS_100;
        (int256 d0, int256 d1) = pool.swap(address(this), zeroForOne, int256(_amount), limit, "");
        (int256 paid, int256 received) = octIsToken0 ? (d1, d0) : (d0, d1);
        sold = uint(paid); bought = uint(-received);
    }

    /// The pool asks for the input token during a swap.
    function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "PolKeeperV3: not the pool");
        int256 owed = octIsToken0 ? _amount1Delta : _amount0Delta;
        if (owed > 0) require(counterToken.transfer(address(pool), uint(owed)), "PolKeeperV3: pay failed");
    }

    function _failed(uint _amount, string memory _reason) internal {
        emit Failed(_amount, _reason);
        if (failedSince == 0) { failedSince = uint64(block.timestamp); return; }
        if (block.timestamp - failedSince < RETRY_WINDOW) return;
        require(collateralToken.approve(address(reserve), _amount), "approve");
        reserve.fill(_amount);
        totalCollReturned += _amount;
        failedSince = 0;
        emit ReturnedToReserve(_amount);
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
