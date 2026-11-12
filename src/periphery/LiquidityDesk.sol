// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Liquidity desk (LS_06 #171): OCT/USDe liquidity provided THROUGH the protocol, so that it belongs to the
* owner's succession plan like the vault and the pool deposits do.
*
* The desk holds one Uniswap v3 position per owner, in the band 0.98 to 1.02 around par, and does everything
* for the owner: mints or adds, collects the fees to the owner, withdraws to the owner. Nothing else can touch
* a position, with one exception: once the Succession Registry has executed the owner's plan, anyone may call
* inherit(owner); the position is unwound and the OCT and USDe go to the heirs by their shares, to the fallback
* heir when a push fails, to escrow when that fails too, exactly like the registry's own pushes.
*
* Liquidity is only accepted while the pool trades within the band (par +/- 2%), so nobody can be made to
* deposit at a manipulated price. TESTNET flavour (Uniswap v3 NFTs); the mainnet Curve flavour holds LP tokens
* with the same shape. No owner, no parameter after deployment.
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
    uint public constant BPS = 10000;

    mapping(address => uint) public positionOf;                   // the owner's NFT id, 0 when none
    mapping(address => mapping(address => uint)) public escrowOf; // heir => token => amount
    uint public totalOctProvided;
    uint public totalCounterProvided;

    event Provided(address indexed owner, uint tokenId, uint oct, uint counter, uint128 liquidity);
    event Collected(address indexed owner, uint oct, uint counter);
    event Withdrawn(address indexed owner, uint oct, uint counter, bool closed);
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
        require(BAND_TICKS % IDeskPool(_pool).tickSpacing() == 0, "LiquidityDesk: band off the grid");
    }

    // --- Views ---

    function liquidityOf(address _owner) external view returns (uint128 liquidity) {
        uint tokenId = positionOf[_owner];
        if (tokenId == 0) return 0;
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    /// Fees already booked to the position (the pool books more on the next touch): a floor, not the total
    function owedOf(address _owner) external view returns (uint oct, uint counter) {
        uint tokenId = positionOf[_owner];
        if (tokenId == 0) return (0, 0);
        (,,,,,,,,,, uint128 owed0, uint128 owed1) = positionManager.positions(tokenId);
        (oct, counter) = octIsToken0 ? (uint(owed0), uint(owed1)) : (uint(owed1), uint(owed0));
    }

    function atPar() public view returns (bool) {
        (, int24 tick,,,,,) = pool.slot0();
        return tick > -BAND_TICKS && tick < BAND_TICKS;
    }

    // --- Owner actions ---

    /// Provide OCT and USDe; what the pool cannot place at the current price comes straight back.
    function provide(uint _octAmount, uint _counterAmount) external returns (uint tokenId, uint octUsed, uint counterUsed) {
        require(_octAmount > 0 || _counterAmount > 0, "LiquidityDesk: nothing to provide");
        require(atPar(), "LiquidityDesk: the pool is off par, wait");
        if (_octAmount > 0) require(octToken.transferFrom(msg.sender, address(this), _octAmount), "LiquidityDesk: OCT transferFrom failed");
        if (_counterAmount > 0) require(counterToken.transferFrom(msg.sender, address(this), _counterAmount), "LiquidityDesk: transferFrom failed");
        require(octToken.approve(address(positionManager), _octAmount) && counterToken.approve(address(positionManager), _counterAmount), "approve");
        (uint a0, uint a1) = octIsToken0 ? (_octAmount, _counterAmount) : (_counterAmount, _octAmount);
        uint128 liquidity; uint u0; uint u1;
        tokenId = positionOf[msg.sender];
        if (tokenId == 0) {
            (tokenId, liquidity, u0, u1) = positionManager.mint(IDeskNPM.MintParams({
                token0: pool.token0(), token1: pool.token1(), fee: pool.fee(), tickLower: -BAND_TICKS, tickUpper: BAND_TICKS,
                amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
            }));
            positionOf[msg.sender] = tokenId;
        } else {
            (liquidity, u0, u1) = positionManager.increaseLiquidity(IDeskNPM.IncreaseLiquidityParams({
                tokenId: tokenId, amount0Desired: a0, amount1Desired: a1, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        (octUsed, counterUsed) = octIsToken0 ? (u0, u1) : (u1, u0);
        if (_octAmount > octUsed) require(octToken.transfer(msg.sender, _octAmount - octUsed), "LiquidityDesk: refund failed");
        if (_counterAmount > counterUsed) require(counterToken.transfer(msg.sender, _counterAmount - counterUsed), "LiquidityDesk: refund failed");
        totalOctProvided += octUsed;
        totalCounterProvided += counterUsed;
        emit Provided(msg.sender, tokenId, octUsed, counterUsed, liquidity);
    }

    /// Collect the fees the position earned, to the owner.
    function collect() external returns (uint oct, uint counter) {
        uint tokenId = positionOf[msg.sender];
        require(tokenId != 0, "LiquidityDesk: no position");
        (oct, counter) = _collect(tokenId, msg.sender);
        emit Collected(msg.sender, oct, counter);
    }

    /// Withdraw part of the liquidity (0 = all) with the fees, to the owner. An emptied position is closed.
    function withdraw(uint128 _liquidity) external returns (uint oct, uint counter) {
        uint tokenId = positionOf[msg.sender];
        require(tokenId != 0, "LiquidityDesk: no position");
        bool closed;
        (oct, counter, closed) = _unwind(tokenId, _liquidity, msg.sender);
        if (closed) delete positionOf[msg.sender];
        emit Withdrawn(msg.sender, oct, counter, closed);
    }

    // --- Succession (permissionless once the registry has executed the owner's plan) ---

    function inherit(address _owner) external {
        (uint8 state,,) = registry.successionState(_owner);
        require(state == 4, "LiquidityDesk: the plan is not executed");
        uint tokenId = positionOf[_owner];
        require(tokenId != 0, "LiquidityDesk: no position");
        delete positionOf[_owner];
        (uint oct, uint counter,) = _unwind(tokenId, 0, address(this));
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

    function _collect(uint _tokenId, address _to) internal returns (uint oct, uint counter) {
        (uint a0, uint a1) = positionManager.collect(IDeskNPM.CollectParams({
            tokenId: _tokenId, recipient: _to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        }));
        (oct, counter) = octIsToken0 ? (a0, a1) : (a1, a0);
    }

    /// Remove liquidity (0 = all) and collect everything, principal and fees, to _to. Burns an emptied NFT.
    function _unwind(uint _tokenId, uint128 _liquidity, address _to) internal returns (uint oct, uint counter, bool closed) {
        (,,,,,,, uint128 held,,,,) = positionManager.positions(_tokenId);
        uint128 part = _liquidity == 0 || _liquidity > held ? held : _liquidity;
        if (part > 0) {
            positionManager.decreaseLiquidity(IDeskNPM.DecreaseLiquidityParams({
                tokenId: _tokenId, liquidity: part, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            }));
        }
        (oct, counter) = _collect(_tokenId, _to);
        closed = part == held;
        if (closed) positionManager.burn(_tokenId);
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
