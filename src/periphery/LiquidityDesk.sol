// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Liquidity desk (LS_06 #171, #177): OCT/USDe liquidity provided THROUGH the protocol, so that it belongs to the
* owner's succession plan like the vault and the pool deposits do.
*
* Three kinds of position, one of each per owner, all on a Uniswap v3 pool through the position manager:
*   the band  (kind 0): OCT and USDe together in the range 0.98 to 1.02 around par, as before;
*   the bid   (kind 1): dollars alone, resting under par (1.0 down to about 0.995), buying OCT when it is sold;
*   the ask   (kind 2): OCT alone, resting above the standing offer (about 1.005 up to 1.02), selling when demand
*                       comes. The buffer's own offer sells first; the asks are the wall above it.
* Nobody sells OCT to join: a dollar holder brings dollars, an OCT holder brings OCT, the price moves the
* positions between the two sides and pays the pool's fee on every fill.
*
* The desk pays the bids. The interest splitter sends it the LP's share of the minted interest; notifyReward()
* books it to the bids per unit of liquidity resting (all bids share one range, so liquidity is proportional
* to dollars). Asks and the band earn the pool's fees only. Income is claimed in OCT.
*
* Succession: once the Succession Registry has executed the owner's plan, anyone may call inherit(owner); every
* position is unwound and the OCT, the USDe and the unclaimed income go to the heirs by their shares, to the
* fallback heir when a push fails, to escrow when that fails too, exactly like the registry's own pushes.
*
* Positions are only accepted while the pool trades on the right side of their range (a bid while OCT is at or
* above par, an ask while it is under the ask range, the band while it is inside the band), so nobody can be made
* to deposit at a manipulated price. TESTNET flavour (Uniswap v3 NFTs). No owner, no parameter after deployment.
*/
interface IDeskERC20 {
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function approve(address, uint) external returns (bool);
}
interface IDeskPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}
interface IDeskNPM {
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    struct IncreaseLiquidityParams { uint tokenId; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; uint deadline; }
    struct DecreaseLiquidityParams { uint tokenId; uint128 liquidity; uint amount0Min; uint amount1Min; uint deadline; }
    struct CollectParams { uint tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata) external payable returns (uint tokenId, uint128 liquidity, uint amount0, uint amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128 liquidity, uint amount0, uint amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint amount0, uint amount1);
    function collect(CollectParams calldata) external payable returns (uint amount0, uint amount1);
    function burn(uint tokenId) external payable;
    function positions(uint tokenId) external view returns (uint96, address, address, address, uint24, int24, int24, uint128 liquidity, uint, uint, uint128 tokensOwed0, uint128 tokensOwed1);
}
interface IDeskRegistry {
    function successionState(address _owner) external view returns (uint8 state, uint dueAt, uint executableAt);
    function getHeirs(address _owner) external view returns (address[] memory accounts, uint16[] memory bps);
    function getFallbackHeir(address _owner) external view returns (address);
}

contract LiquidityDesk {
    IDeskERC20 public immutable octToken;
    IDeskERC20 public immutable counterToken;    // USDe on the testnet
    IDeskPool public immutable pool;
    IDeskNPM public immutable positionManager;
    IDeskRegistry public immutable registry;
    bool public immutable octIsToken0;
    int24 public constant BAND_TICKS = 200;      // the band: 0.98 to 1.02 around par
    int24 public immutable bidTicks;             // the bids rest from par down to about 0.995 (50 ticks, on the pool's grid)
    int24 public immutable askLower;             // the asks start above the standing offer (about 1.005, on the grid)
    int24 public immutable askUpper;             // and end at the band's edge
    uint public constant BPS = 10000;
    uint public constant RAY = 1e27;

    uint8 public constant BAND = 0; uint8 public constant BID = 1; uint8 public constant ASK = 2;

    mapping(address => uint) public positionOf;                   // the band position's NFT id, 0 when none
    mapping(address => uint) public bidOf;                        // the bid position's NFT id
    mapping(address => uint) public askOf;                        // the ask position's NFT id
    mapping(address => mapping(address => uint)) public escrowOf; // heir => token => amount
    uint public totalOctProvided;
    uint public totalCounterProvided;
    mapping(address => uint) public octOf;                        // OCT principal an owner has in the band
    mapping(address => uint) public askOctOf;                     // OCT principal an owner has in his ask
    uint public octInPositions;                                   // OCT principal in all open positions (a measure for the POL target)

    // the bids' income: OCT per unit of bid liquidity, RAY-scaled
    uint128 public totalBidLiquidity;
    mapping(address => uint128) public bidLiquidityOf;
    uint public rewardIndex;
    mapping(address => uint) public rewardSnapshotOf;
    mapping(address => uint) public rewardOwedOf;
    uint public rewardAccounted;                                  // booked to bids and not yet claimed
    uint public totalRewardNotified;
    uint public totalRewardPaid;

    event Provided(address indexed owner, uint8 kind, uint tokenId, uint oct, uint counter, uint128 liquidity);
    event Collected(address indexed owner, uint oct, uint counter);
    event Withdrawn(address indexed owner, uint8 kind, uint oct, uint counter, bool closed);
    event RewardNotified(uint amount, uint rewardIndex);
    event RewardClaimed(address indexed owner, uint amount);
    event Inherited(address indexed owner, address indexed heir, uint oct, uint counter);
    event Escrowed(address indexed heir, address token, uint amount);
    event EscrowClaimed(address indexed heir, address token, uint amount);

    constructor(address _octToken, address _pool, address _positionManager, address _registry) {
        require(_octToken != address(0) && _pool != address(0) && _positionManager != address(0) && _registry != address(0), "LiquidityDesk: zero address");
        octToken = IDeskERC20(_octToken);
        pool = IDeskPool(_pool);
        positionManager = IDeskNPM(_positionManager);
        registry = IDeskRegistry(_registry);
        address t0 = IDeskPool(_pool).token0(); address t1 = IDeskPool(_pool).token1();
        octIsToken0 = t0 == _octToken;
        require(octIsToken0 || t1 == _octToken, "LiquidityDesk: OCT is not in the pool");
        counterToken = IDeskERC20(octIsToken0 ? t1 : t0);
        int24 spacing = IDeskPool(_pool).tickSpacing();
        require(spacing > 0 && BAND_TICKS % spacing == 0, "LiquidityDesk: band off the grid");
        int24 half = _ceilTo(50, spacing);          // 50 ticks is 0.5%, the standing offer's premium
        bidTicks = half; askLower = half; askUpper = BAND_TICKS;
        require(askLower < askUpper, "LiquidityDesk: grid too coarse");
    }

    // --- Views ---

    function liquidityOf(address _owner) external view returns (uint128 liquidity) { return _held(positionOf[_owner]); }
    function askLiquidityOf(address _owner) external view returns (uint128 liquidity) { return _held(askOf[_owner]); }

    /// The owner's three positions: band, bid, ask (0 when none)
    function positionsOf(address _owner) external view returns (uint band, uint bid, uint ask) {
        return (positionOf[_owner], bidOf[_owner], askOf[_owner]);
    }
    function hasPositions(address _owner) public view returns (bool) {
        return positionOf[_owner] != 0 || bidOf[_owner] != 0 || askOf[_owner] != 0;
    }

    /// Fees already booked to the owner's positions (the pool books more on the next touch): a floor, not the total
    function owedOf(address _owner) external view returns (uint oct, uint counter) {
        (uint o0, uint c0) = _owed(positionOf[_owner]); (uint o1, uint c1) = _owed(bidOf[_owner]); (uint o2, uint c2) = _owed(askOf[_owner]);
        return (o0 + o1 + o2, c0 + c1 + c2);
    }

    /// OCT income a bid has earned and not claimed
    function rewardOf(address _owner) public view returns (uint) {
        return rewardOwedOf[_owner] + uint(bidLiquidityOf[_owner]) * (rewardIndex - rewardSnapshotOf[_owner]) / RAY;
    }

    function currentTick() public view returns (int24 tick) { (, tick,,,,,) = pool.slot0(); }
    function atPar() public view returns (bool) { int24 tick = currentTick(); return tick > -BAND_TICKS && tick < BAND_TICKS; }
    /// A bid can be placed while OCT is at or above par (the range is entirely under the price)
    function bidPlaceable() public view returns (bool) { int24 tick = currentTick(); return octIsToken0 ? tick >= 0 : tick <= 0; }
    /// An ask can be placed while OCT is under the ask range (the range is entirely above the price)
    function askPlaceable() public view returns (bool) { int24 tick = currentTick(); return octIsToken0 ? tick <= askLower : tick >= -askLower; }

    /// The tick ranges of the three kinds, as the pool sees them
    function rangeOf(uint8 _kind) public view returns (int24 lower, int24 upper) {
        if (_kind == BAND) return (-BAND_TICKS, BAND_TICKS);
        if (_kind == BID) return octIsToken0 ? (-bidTicks, int24(0)) : (int24(0), bidTicks);
        return octIsToken0 ? (askLower, askUpper) : (-askUpper, -askLower);
    }

    // --- Owner actions ---

    /// The band: provide OCT and USDe together; what the pool cannot place at the current price comes straight back.
    function provide(uint _octAmount, uint _counterAmount) external returns (uint tokenId, uint octUsed, uint counterUsed) {
        require(_octAmount > 0 || _counterAmount > 0, "LiquidityDesk: nothing to provide");
        require(atPar(), "LiquidityDesk: the pool is off par, wait");
        _pull(_octAmount, _counterAmount);
        uint128 liquidity;
        (tokenId, liquidity, octUsed, counterUsed) = _place(positionOf[msg.sender], BAND, _octAmount, _counterAmount);
        positionOf[msg.sender] = tokenId;
        _refund(_octAmount - octUsed, _counterAmount - counterUsed);
        totalOctProvided += octUsed; totalCounterProvided += counterUsed;
        octOf[msg.sender] += octUsed; octInPositions += octUsed;
        emit Provided(msg.sender, BAND, tokenId, octUsed, counterUsed, liquidity);
    }

    /// The bid: dollars alone, resting under par. Paid the LP's share of the interest while they rest.
    function provideCounter(uint _counterAmount) external returns (uint tokenId, uint counterUsed) {
        require(_counterAmount > 0, "LiquidityDesk: nothing to provide");
        require(bidPlaceable(), "LiquidityDesk: OCT is under par right now, wait");
        _accrue(msg.sender);
        _pull(0, _counterAmount);
        uint128 liquidity; uint octUsed;
        (tokenId, liquidity, octUsed, counterUsed) = _place(bidOf[msg.sender], BID, 0, _counterAmount);
        require(octUsed == 0 && counterUsed > 0, "LiquidityDesk: the bid took nothing");
        bidOf[msg.sender] = tokenId;
        _refund(0, _counterAmount - counterUsed);
        totalCounterProvided += counterUsed;
        bidLiquidityOf[msg.sender] += liquidity; totalBidLiquidity += liquidity;
        emit Provided(msg.sender, BID, tokenId, 0, counterUsed, liquidity);
    }

    /// The ask: OCT alone, resting above the standing offer. Earns the pool's fees.
    function provideOct(uint _octAmount) external returns (uint tokenId, uint octUsed) {
        require(_octAmount > 0, "LiquidityDesk: nothing to provide");
        require(askPlaceable(), "LiquidityDesk: OCT is above the offer right now, wait");
        _pull(_octAmount, 0);
        uint128 liquidity; uint counterUsed;
        (tokenId, liquidity, octUsed, counterUsed) = _place(askOf[msg.sender], ASK, _octAmount, 0);
        require(counterUsed == 0 && octUsed > 0, "LiquidityDesk: the ask took nothing");
        askOf[msg.sender] = tokenId;
        _refund(_octAmount - octUsed, 0);
        totalOctProvided += octUsed;
        askOctOf[msg.sender] += octUsed; octInPositions += octUsed;
        emit Provided(msg.sender, ASK, tokenId, octUsed, 0, liquidity);
    }

    /// Collect the fees every position earned, to the owner.
    function collect() external returns (uint oct, uint counter) {
        require(hasPositions(msg.sender), "LiquidityDesk: no position");
        (oct, counter) = _collectAll(msg.sender, msg.sender);
        emit Collected(msg.sender, oct, counter);
    }

    /// Claim the OCT income the bid earned.
    function claim() external returns (uint amount) {
        _accrue(msg.sender);
        amount = rewardOwedOf[msg.sender];
        require(amount > 0, "LiquidityDesk: nothing to claim");
        rewardOwedOf[msg.sender] = 0;
        _payReward(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// Withdraw part of the band's liquidity (0 = all) with its fees, to the owner. An emptied position is closed.
    function withdraw(uint128 _liquidity) external returns (uint oct, uint counter) {
        uint tokenId = positionOf[msg.sender];
        require(tokenId != 0, "LiquidityDesk: no position");
        uint128 held = _held(tokenId);
        bool closed;
        (oct, counter, closed) = _unwind(tokenId, _liquidity, msg.sender);
        _releaseBand(msg.sender, closed ? octOf[msg.sender] : held == 0 ? 0 : octOf[msg.sender] * _part(_liquidity, held) / held);
        if (closed) delete positionOf[msg.sender];
        emit Withdrawn(msg.sender, BAND, oct, counter, closed);
    }

    /// Withdraw part of the bid (0 = all): the dollars still resting and the OCT it bought, with the fees and the income.
    function withdrawBid(uint128 _liquidity) external returns (uint oct, uint counter) {
        uint tokenId = bidOf[msg.sender];
        require(tokenId != 0, "LiquidityDesk: no bid");
        _accrue(msg.sender);
        uint128 held = _held(tokenId);
        uint128 part = _part(_liquidity, held);
        bool closed;
        (oct, counter, closed) = _unwind(tokenId, _liquidity, msg.sender);
        bidLiquidityOf[msg.sender] -= part; totalBidLiquidity -= part;
        if (closed) delete bidOf[msg.sender];
        uint income = rewardOwedOf[msg.sender];
        if (income > 0) { rewardOwedOf[msg.sender] = 0; _payReward(msg.sender, income); emit RewardClaimed(msg.sender, income); }
        emit Withdrawn(msg.sender, BID, oct, counter, closed);
    }

    /// Withdraw part of the ask (0 = all): the OCT still resting and the dollars it sold for, with the fees.
    function withdrawAsk(uint128 _liquidity) external returns (uint oct, uint counter) {
        uint tokenId = askOf[msg.sender];
        require(tokenId != 0, "LiquidityDesk: no ask");
        uint128 held = _held(tokenId);
        bool closed;
        (oct, counter, closed) = _unwind(tokenId, _liquidity, msg.sender);
        _releaseAsk(msg.sender, closed ? askOctOf[msg.sender] : held == 0 ? 0 : askOctOf[msg.sender] * _part(_liquidity, held) / held);
        if (closed) delete askOf[msg.sender];
        emit Withdrawn(msg.sender, ASK, oct, counter, closed);
    }

    // --- The bids' income (the interest splitter pays it in) ---

    /// Book OCT already transferred here to the bids, per unit of liquidity resting. Anyone may add to the bids' income.
    function notifyReward(uint _amount) external {
        require(_amount > 0, "LiquidityDesk: zero reward");
        require(totalBidLiquidity > 0, "LiquidityDesk: no bids to pay");
        require(octToken.balanceOf(address(this)) >= rewardAccounted + _amount, "LiquidityDesk: reward not received");
        rewardIndex += _amount * RAY / totalBidLiquidity;
        rewardAccounted += _amount; totalRewardNotified += _amount;
        emit RewardNotified(_amount, rewardIndex);
    }

    // --- Succession (permissionless once the registry has executed the owner's plan) ---

    function inherit(address _owner) external {
        (uint8 state,,) = registry.successionState(_owner);
        require(state == 4, "LiquidityDesk: the plan is not executed");
        require(hasPositions(_owner) || rewardOf(_owner) > 0, "LiquidityDesk: no position");
        _accrue(_owner);
        uint oct; uint counter;
        if (positionOf[_owner] != 0) { (uint o, uint c,) = _unwind(positionOf[_owner], 0, address(this)); oct += o; counter += c; delete positionOf[_owner]; _releaseBand(_owner, octOf[_owner]); }
        if (bidOf[_owner] != 0) { (uint o, uint c,) = _unwind(bidOf[_owner], 0, address(this)); oct += o; counter += c; delete bidOf[_owner]; totalBidLiquidity -= bidLiquidityOf[_owner]; bidLiquidityOf[_owner] = 0; }
        if (askOf[_owner] != 0) { (uint o, uint c,) = _unwind(askOf[_owner], 0, address(this)); oct += o; counter += c; delete askOf[_owner]; _releaseAsk(_owner, askOctOf[_owner]); }
        uint income = rewardOwedOf[_owner];
        if (income > 0) { rewardOwedOf[_owner] = 0; rewardAccounted -= income; totalRewardPaid += income; oct += income; }
        (address[] memory heirs, uint16[] memory bps) = registry.getHeirs(_owner);
        address fallbackHeir = registry.getFallbackHeir(_owner);
        uint n = heirs.length;
        uint octLeft = oct; uint counterLeft = counter;
        for (uint i = 0; i < n; i++) {
            uint octShare = (i == n - 1) ? octLeft : oct * bps[i] / BPS;
            uint counterShare = (i == n - 1) ? counterLeft : counter * bps[i] / BPS;
            octLeft -= octShare; counterLeft -= counterShare;
            _push(heirs[i], fallbackHeir, address(octToken), octShare);
            _push(heirs[i], fallbackHeir, address(counterToken), counterShare);
            emit Inherited(_owner, heirs[i], octShare, counterShare);
        }
    }

    function claimEscrow(address _token) external {
        uint amount = escrowOf[msg.sender][_token];
        require(amount > 0, "LiquidityDesk: nothing in escrow");
        escrowOf[msg.sender][_token] = 0;
        require(IDeskERC20(_token).transfer(msg.sender, amount), "LiquidityDesk: transfer failed");
        emit EscrowClaimed(msg.sender, _token, amount);
    }

    // --- Internal ---

    function _ceilTo(int24 _ticks, int24 _spacing) internal pure returns (int24) {
        int24 r = _ticks % _spacing;
        return r == 0 ? _ticks : _ticks + (_spacing - r);
    }

    function _held(uint _tokenId) internal view returns (uint128 liquidity) {
        if (_tokenId == 0) return 0;
        (,,,,,,, liquidity,,,,) = positionManager.positions(_tokenId);
    }

    function _owed(uint _tokenId) internal view returns (uint oct, uint counter) {
        if (_tokenId == 0) return (0, 0);
        (,,,,,,,,,, uint128 owed0, uint128 owed1) = positionManager.positions(_tokenId);
        (oct, counter) = octIsToken0 ? (uint(owed0), uint(owed1)) : (uint(owed1), uint(owed0));
    }

    function _part(uint128 _liquidity, uint128 _held) internal pure returns (uint128) {
        return _liquidity == 0 || _liquidity > _held ? _held : _liquidity;
    }

    function _pull(uint _oct, uint _counter) internal {
        if (_oct > 0) require(octToken.transferFrom(msg.sender, address(this), _oct), "LiquidityDesk: OCT transferFrom failed");
        if (_counter > 0) require(counterToken.transferFrom(msg.sender, address(this), _counter), "LiquidityDesk: transferFrom failed");
    }

    function _refund(uint _oct, uint _counter) internal {
        if (_oct > 0) require(octToken.transfer(msg.sender, _oct), "LiquidityDesk: refund failed");
        if (_counter > 0) require(counterToken.transfer(msg.sender, _counter), "LiquidityDesk: refund failed");
    }

    /// Mint a position of the kind, or add to the owner's existing one
    function _place(uint _tokenId, uint8 _kind, uint _oct, uint _counter) internal returns (uint tokenId, uint128 liquidity, uint octUsed, uint counterUsed) {
        require(octToken.approve(address(positionManager), _oct) && counterToken.approve(address(positionManager), _counter), "approve");
        (uint a0, uint a1) = octIsToken0 ? (_oct, _counter) : (_counter, _oct);
        uint u0; uint u1;
        tokenId = _tokenId;
        if (tokenId == 0) {
            (int24 lower, int24 upper) = rangeOf(_kind);
            (tokenId, liquidity, u0, u1) = positionManager.mint(IDeskNPM.MintParams({
                token0: pool.token0(), token1: pool.token1(), fee: pool.fee(), tickLower: lower, tickUpper: upper,
                amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
            }));
        } else {
            (liquidity, u0, u1) = positionManager.increaseLiquidity(IDeskNPM.IncreaseLiquidityParams({
                tokenId: tokenId, amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        (octUsed, counterUsed) = octIsToken0 ? (u0, u1) : (u1, u0);
    }

    function _collect(uint _tokenId, address _to) internal returns (uint oct, uint counter) {
        if (_tokenId == 0) return (0, 0);
        (uint a0, uint a1) = positionManager.collect(IDeskNPM.CollectParams({
            tokenId: _tokenId, recipient: _to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        (oct, counter) = octIsToken0 ? (a0, a1) : (a1, a0);
    }

    function _collectAll(address _owner, address _to) internal returns (uint oct, uint counter) {
        (uint o0, uint c0) = _collect(positionOf[_owner], _to); (uint o1, uint c1) = _collect(bidOf[_owner], _to); (uint o2, uint c2) = _collect(askOf[_owner], _to);
        return (o0 + o1 + o2, c0 + c1 + c2);
    }

    /// Remove liquidity (0 = all) and collect everything, principal and fees, to _to. Burns an emptied NFT.
    function _unwind(uint _tokenId, uint128 _liquidity, address _to) internal returns (uint oct, uint counter, bool closed) {
        uint128 held = _held(_tokenId);
        uint128 part = _part(_liquidity, held);
        if (part > 0) {
            positionManager.decreaseLiquidity(IDeskNPM.DecreaseLiquidityParams({
                tokenId: _tokenId, liquidity: part, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        (oct, counter) = _collect(_tokenId, _to);
        closed = part == held;
        if (closed) positionManager.burn(_tokenId);
    }

    function _accrue(address _owner) internal {
        uint owed = rewardOf(_owner);
        rewardOwedOf[_owner] = owed;
        rewardSnapshotOf[_owner] = rewardIndex;
    }

    function _payReward(address _to, uint _amount) internal {
        rewardAccounted -= _amount; totalRewardPaid += _amount;
        require(octToken.transfer(_to, _amount), "LiquidityDesk: income transfer failed");
    }

    function _releaseBand(address _owner, uint _oct) internal {
        if (_oct > octOf[_owner]) _oct = octOf[_owner];
        octOf[_owner] -= _oct;
        octInPositions -= _oct;
    }

    function _releaseAsk(address _owner, uint _oct) internal {
        if (_oct > askOctOf[_owner]) _oct = askOctOf[_owner];
        askOctOf[_owner] -= _oct;
        octInPositions -= _oct;
    }

    function _push(address _heir, address _fallbackHeir, address _token, uint _amount) internal {
        if (_amount == 0) return;
        if (_tryTransfer(_token, _heir, _amount)) return;
        if (_fallbackHeir != address(0) && _tryTransfer(_token, _fallbackHeir, _amount)) return;
        escrowOf[_heir][_token] += _amount;
        emit Escrowed(_heir, _token, _amount);
    }

    function _tryTransfer(address _token, address _to, uint _amount) internal returns (bool) {
        try IDeskERC20(_token).transfer(_to, _amount) returns (bool ok) { return ok; } catch { return false; }
    }

    /// The position manager hands the NFT over with a safeTransfer check; accept it.
    function onERC721Received(address, address, uint, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
