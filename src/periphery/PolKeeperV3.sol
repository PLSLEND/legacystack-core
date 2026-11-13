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
* Fees (#169, #170, #172): `harvest()` collects what the positions earned. Fees in the counter-asset are turned
* into OCT inside the pool, only while OCT trades at or below par and never above 1% over it (a bid that can
* only help the peg); otherwise they wait here. The OCT then goes one of two ways, by a rule and never by a
* key: while the protocol-owned liquidity is BELOW ITS TARGET (POL_TARGET_BPS of the circulating OCT; the seed
* plus everything the keeper placed, counted in OCT), the fees COMPOUND into a new position, deepening the
* liquidity that holds the peg; once the target is reached, the fees go to the reserve's inventory and feed
* the reserve, the waterfall and the rest. The same target tells the splitter how much of the reserve's
* surplus to send here (all of it below target, half above). Fees can only ever sit in the pool or in the
* protocol; nobody can take them out.
*
* Seed (#170): the deployment sends the pool's opening liquidity (OCT and the counter-asset) here and calls
* `seed()` once; the keeper places it two-sided around par (0.98 to 1.02) and holds it forever, so the
* protocol's seed is the protocol's and counts in its share. The deployer can do nothing else, ever.
*
* Failure (#169): if the pool step fails, the whole conversion is undone and the wstETH stays here for the
* next run; only after 90 days of failing does it go back to the reserve pot, so a dead venue can never trap
* funds and nothing is ever thrown away. Permissionless; no owner; no parameter after deployment.
*/
interface IPolERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); function approve(address, uint) external returns (bool); }
interface IPolBuffer {
    function inventory() external view returns (uint);
    function circulatingSupply() external view returns (uint);
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
    address public immutable deployer;              // may call seed() once; nothing else
    uint32 public constant TWAP_WINDOW = 1 hours;
    int24 public constant RANGE_TICKS = 100;        // the one-sided band: ~1% wide, just beside the price
    int24 public constant SEED_TICKS = 200;         // the seed band: 0.98 to 1.02 around par
    uint public constant RETRY_WINDOW = 90 days;    // a venue that fails this long gives the wstETH back to the reserve
    uint public constant POL_TARGET_BPS = 1000;     // the protocol's own liquidity aims at 10% of the circulating OCT
    // sqrt prices at ticks +100 and -100: the harvest never buys OCT more than 1% over par
    uint160 internal constant SQRT_TICK_PLUS_100 = 79625275426524748796330556127;
    uint160 internal constant SQRT_TICK_MINUS_100 = 78833030112140176575862854578;

    uint public seedOct;                            // the opening liquidity placed through seed(): OCT plus counter-asset, ~$1 each
    uint public totalOctDeposited;
    uint public totalCollConverted;
    uint public totalCollReturned;                  // wstETH returned to the reserve after a dead spell
    uint public totalOctHarvested;                  // OCT fees sent to the reserve (fees collected plus fees bought)
    uint public totalOctCompounded;                 // OCT fees placed back into the pool
    uint public totalCounterHarvested;              // counter-asset fees collected
    uint64 public failedSince;                      // first failed run of the current dead spell, 0 when healthy
    uint[] public positions;                        // NFT ids held forever

    event Seeded(uint tokenId, uint oct, uint counter);
    event Deposited(uint tokenId, uint octIn, int24 tickLower, int24 tickUpper);
    event Failed(uint collAmount, string reason);
    event ReturnedToReserve(uint collAmount);
    event Harvested(uint octCollected, uint counterCollected, uint counterSold, uint octBought, uint octToReserve, uint octCompounded);

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
        deployer = msg.sender;
        try IPolPool(_pool).increaseObservationCardinalityNext(60) {} catch {}
    }

    function positionCount() external view returns (uint) { return positions.length; }

    /// Once, by the deployer: place the OCT and counter-asset sent here as the pool's opening liquidity,
    /// two-sided around par, held forever like every other position.
    function seed() external returns (uint tokenId) {
        require(msg.sender == deployer, "PolKeeperV3: deployer only");
        require(seedOct == 0, "PolKeeperV3: seeded");
        uint oct = octToken.balanceOf(address(this));
        uint counter = counterToken.balanceOf(address(this));
        require(oct > 0 && counter > 0, "PolKeeperV3: nothing to seed");
        require(octToken.approve(address(positionManager), oct) && counterToken.approve(address(positionManager), counter), "approve");
        uint a0; uint a1;
        (tokenId,, a0, a1) = positionManager.mint(IPolNPM.MintParams({
            token0: pool.token0(), token1: pool.token1(), fee: pool.fee(), tickLower: -SEED_TICKS, tickUpper: SEED_TICKS,
            amount0Desired: octIsToken0 ? oct : counter, amount1Desired: octIsToken0 ? counter : oct,
            amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
        }));
        positions.push(tokenId);
        seedOct = a0 + a1;
        emit Seeded(tokenId, octIsToken0 ? a0 : a1, octIsToken0 ? a1 : a0);
    }

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

    /// The protocol's share of the pool: the seed plus the OCT the keeper placed, against everything the pool
    /// holds (both tokens, ~$1 each). A measure, not a vault: what others add shrinks it, what they remove grows it.
    /// The protocol-owned liquidity, in OCT: the seed plus everything the keeper placed (OCT and compounded fees)
    function polValue() public view returns (uint) {
        return seedOct + totalOctDeposited;
    }

    /// Where the protocol's own liquidity should stand: POL_TARGET_BPS of the circulating OCT
    function polTarget() public view returns (uint) {
        return reserve.circulatingSupply() * POL_TARGET_BPS / 10000;
    }

    function belowTarget() public view returns (bool) {
        return polValue() < polTarget();
    }

    function protocolShare() public view returns (uint) {
        uint held = octToken.balanceOf(address(pool)) + counterToken.balanceOf(address(pool));
        if (held == 0) return 1e18;
        uint ours = seedOct + totalOctDeposited;
        if (ours > held) ours = held;
        return ours * 1e18 / held;
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
        _place(oct);
        totalCollConverted += collIn;
    }

    /// Internal step exposed only to itself: harvested OCT back into the pool as a new one-sided position.
    function placeOct(uint _oct) external {
        require(msg.sender == address(this), "PolKeeperV3: internal");
        _place(_oct);
        totalOctCompounded += _oct;
    }

    function _place(uint oct) internal {
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
        emit Deposited(tokenId, oct, lower, upper);
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
        // the OCT in hand (collected, bought, or left from an earlier harvest): compound while the protocol's
        // liquidity is below its target and OCT is at or above par, otherwise to the reserve; below par it waits
        uint oct = octToken.balanceOf(address(this));
        uint octCompounded;
        if (oct > 0) {
            if (belowTarget()) {
                if (octAtOrAbovePar()) { try this.placeOct(oct) { octCompounded = oct; } catch {} }
            } else {
                require(octToken.transfer(address(reserve), oct), "PolKeeperV3: transfer failed");
                totalOctHarvested += oct;
                octToReserve = oct;
            }
        }
        emit Harvested(octCollected, counterCollected, counterSold, octBought, octToReserve, octCompounded);
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
