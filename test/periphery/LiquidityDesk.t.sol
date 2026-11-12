// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../base/LegacyStackBase.sol";

interface IDesk {
    function provide(uint, uint) external returns (uint, uint, uint);
    function collect() external returns (uint, uint);
    function withdraw(uint128) external returns (uint, uint);
    function inherit(address) external;
    function claimEscrow(address) external;
    function positionOf(address) external view returns (uint);
    function liquidityOf(address) external view returns (uint128);
    function owedOf(address) external view returns (uint, uint);
    function atPar() external view returns (bool);
    function totalOctProvided() external view returns (uint);
    function escrowOf(address, address) external view returns (uint);
}
interface IERC20D { function transferFrom(address, address, uint) external returns (bool); function transfer(address, uint) external returns (bool); function balanceOf(address) external view returns (uint); function mint(address, uint) external; function approve(address, uint) external returns (bool); }

/// A stand-in for the pool: tokens, fee tier, spacing and the current tick.
contract DeskPoolMock {
    address public token0; address public token1; uint24 public fee = 500; int24 public tickSpacing = 10; int24 public tick;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setTick(int24 t) external { tick = t; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) { return (0, tick, 0, 0, 0, 0, true); }
}

/// A stand-in for the position manager, at par: a position uses equal amounts of both tokens, liquidity is
/// their sum, decreasing returns them in proportion, fees are booked with setFees and paid by collect.
contract DeskNPMMock {
    struct P { address token0; address token1; uint amount0; uint amount1; uint128 liquidity; uint128 owed0; uint128 owed1; address owner; bool burned; }
    mapping(uint => P) public pos; uint public minted;
    struct MintParams { address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; address recipient; uint deadline; }
    struct IncreaseLiquidityParams { uint tokenId; uint amount0Desired; uint amount1Desired; uint amount0Min; uint amount1Min; uint deadline; }
    struct DecreaseLiquidityParams { uint tokenId; uint128 liquidity; uint amount0Min; uint amount1Min; uint deadline; }
    struct CollectParams { uint tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    int24 public lastLower; int24 public lastUpper;
    function mint(MintParams calldata p) external returns (uint tokenId, uint128 liquidity, uint a0, uint a1) {
        a0 = p.amount0Desired < p.amount1Desired ? p.amount0Desired : p.amount1Desired; a1 = a0;
        _pull(p.token0, p.token1, a0, a1);
        minted++; tokenId = minted; lastLower = p.tickLower; lastUpper = p.tickUpper;
        liquidity = uint128(a0 + a1);
        pos[tokenId] = P(p.token0, p.token1, a0, a1, liquidity, 0, 0, p.recipient, false);
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata p) external returns (uint128 liquidity, uint a0, uint a1) {
        P storage x = pos[p.tokenId];
        a0 = p.amount0Desired < p.amount1Desired ? p.amount0Desired : p.amount1Desired; a1 = a0;
        _pull(x.token0, x.token1, a0, a1);
        liquidity = uint128(a0 + a1); x.liquidity += liquidity; x.amount0 += a0; x.amount1 += a1;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external returns (uint a0, uint a1) {
        P storage x = pos[p.tokenId];
        require(p.liquidity <= x.liquidity, "too much");
        a0 = x.amount0 * p.liquidity / x.liquidity; a1 = x.amount1 * p.liquidity / x.liquidity;
        x.amount0 -= a0; x.amount1 -= a1; x.liquidity -= p.liquidity; x.owed0 += uint128(a0); x.owed1 += uint128(a1);
    }
    function collect(CollectParams calldata p) external returns (uint a0, uint a1) {
        P storage x = pos[p.tokenId];
        a0 = x.owed0; a1 = x.owed1; x.owed0 = 0; x.owed1 = 0;
        if (a0 > 0) require(IERC20D(x.token0).transfer(p.recipient, a0), "t0");
        if (a1 > 0) require(IERC20D(x.token1).transfer(p.recipient, a1), "t1");
    }
    function burn(uint tokenId) external { P storage x = pos[tokenId]; require(x.liquidity == 0 && x.owed0 == 0 && x.owed1 == 0, "not empty"); x.burned = true; }
    function positions(uint tokenId) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint, uint, uint128, uint128) {
        P storage x = pos[tokenId];
        return (0, address(0), x.token0, x.token1, 500, -200, 200, x.liquidity, 0, 0, x.owed0, x.owed1);
    }
    function ownerOf(uint tokenId) external view returns (address) { require(!pos[tokenId].burned, "burned"); return pos[tokenId].owner; }
    /// the pool books fees to the position (the tokens come from outside, as fees do)
    function setFees(uint tokenId, uint f0, uint f1) external { pos[tokenId].owed0 += uint128(f0); pos[tokenId].owed1 += uint128(f1); }
    function _pull(address t0, address t1, uint a0, uint a1) internal {
        if (a0 > 0) require(IERC20D(t0).transferFrom(msg.sender, address(this), a0), "pull0");
        if (a1 > 0) require(IERC20D(t1).transferFrom(msg.sender, address(this), a1), "pull1");
    }
}

contract LiquidityDeskTest is LegacyStackBase {
    address desk; address usde; DeskPoolMock poolMock; DeskNPMMock npmMock;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        usde = deployCode("src/testnet/MockUSDe.sol:MockUSDe");
        poolMock = new DeskPoolMock(oct, usde);
        npmMock = new DeskNPMMock();
        desk = deployCode("src/periphery/LiquidityDesk.sol:LiquidityDesk", abi.encode(oct, address(poolMock), address(npmMock), registry));
        _open(alice, 20 ether, 10000e18);
        IERC20D(usde).mint(alice, 10000e18);
        vm.startPrank(alice);
        IERC20D(oct).approve(desk, type(uint).max); IERC20D(usde).approve(desk, type(uint).max);
        vm.stopPrank();
    }

    function _provide(address who, uint o, uint u) internal returns (uint tokenId, uint octUsed, uint usdeUsed) {
        vm.prank(who); return IDesk(desk).provide(o, u);
    }

    function test_provideAddsAndRefundsWhatThePoolCannotPlace() public {
        uint octBefore = IERC20L(oct).balanceOf(alice);
        (uint tokenId, uint octUsed, uint usdeUsed) = _provide(alice, 1000e18, 600e18);
        assertEq(tokenId, 1);
        assertEq(octUsed, 600e18); assertEq(usdeUsed, 600e18);                // at par the pool takes equal amounts
        assertEq(octBefore - IERC20L(oct).balanceOf(alice), 600e18, "the rest came back");
        assertEq(IDesk(desk).positionOf(alice), 1);
        assertEq(IDesk(desk).liquidityOf(alice), 1200e18);
        assertEq(npmMock.ownerOf(1), desk, "the desk holds the position");
        assertEq(npmMock.lastLower(), -200); assertEq(npmMock.lastUpper(), 200);
        // a second provide grows the same position
        (uint tokenId2,,) = _provide(alice, 400e18, 400e18);
        assertEq(tokenId2, 1);
        assertEq(IDesk(desk).liquidityOf(alice), 2000e18);
        assertEq(IDesk(desk).totalOctProvided(), 1000e18);
        // off par the desk waits
        poolMock.setTick(250);
        assertFalse(IDesk(desk).atPar());
        vm.prank(alice); vm.expectRevert("LiquidityDesk: the pool is off par, wait");
        IDesk(desk).provide(1e18, 1e18);
    }

    function test_feesGoToTheOwnerAndWithdrawalClosesThePosition() public {
        (uint tokenId,,) = _provide(alice, 1000e18, 1000e18);
        // the position earned 3 OCT and 5 USDe
        _open(bob, 20 ether, 5000e18);
        vm.prank(bob); IERC20L(oct).transfer(address(npmMock), 3e18);
        IERC20D(usde).mint(address(npmMock), 5e18);
        npmMock.setFees(tokenId, poolMock.token0() == oct ? 3e18 : 5e18, poolMock.token0() == oct ? 5e18 : 3e18);
        (uint o, uint u) = IDesk(desk).owedOf(alice);
        assertEq(o, 3e18); assertEq(u, 5e18);
        uint octBefore = IERC20L(oct).balanceOf(alice); uint usdeBefore = IERC20D(usde).balanceOf(alice);
        vm.prank(alice); (uint co, uint cu) = IDesk(desk).collect();
        assertEq(co, 3e18); assertEq(cu, 5e18);
        assertEq(IERC20L(oct).balanceOf(alice), octBefore + 3e18); assertEq(IERC20D(usde).balanceOf(alice), usdeBefore + 5e18);
        // half out, the position stays open
        vm.prank(alice); (uint wo, uint wu) = IDesk(desk).withdraw(1000e18);
        assertEq(wo, 500e18); assertEq(wu, 500e18);
        assertEq(IDesk(desk).liquidityOf(alice), 1000e18);
        // the rest out: closed and burned
        vm.prank(alice); (wo, wu) = IDesk(desk).withdraw(0);
        assertEq(wo, 500e18); assertEq(wu, 500e18);
        assertEq(IDesk(desk).positionOf(alice), 0);
        vm.expectRevert("burned"); npmMock.ownerOf(tokenId);
        vm.prank(alice); vm.expectRevert("LiquidityDesk: no position"); IDesk(desk).withdraw(0);
        // nobody else can touch it
        _provide(alice, 100e18, 100e18);
        vm.prank(carol); vm.expectRevert("LiquidityDesk: no position"); IDesk(desk).withdraw(0);
    }

    function test_liquidityPassesToTheHeirsOnceThePlanIsExecuted() public {
        _provide(alice, 1000e18, 1000e18);
        address[] memory heirs = new address[](2); heirs[0] = carol; heirs[1] = dave;
        uint16[] memory bps = new uint16[](2); bps[0] = 7000; bps[1] = 3000;
        vm.prank(alice); IRegistry(registry).setPlan(heirs, bps, address(0));
        // alive: nobody can move it
        vm.expectRevert("LiquidityDesk: the plan is not executed");
        IDesk(desk).inherit(alice);
        // a year of silence, thirty days of grace: the registry settles the estate (the vault, the pool deposits)
        vm.warp(block.timestamp + 395 days + 1);
        _open(bob, 60 ether, 30000e18);                                 // settlement liquidity for alice's vault
        vm.prank(bob); ISP(sp).provideToSP(20000e18);
        IRegistry(registry).execute(alice);
        (uint8 state,,) = IRegistry(registry).successionState(alice);
        assertEq(state, 4);
        // then anyone unwinds the liquidity to the heirs, by their shares
        uint cO = IERC20L(oct).balanceOf(carol); uint dO = IERC20L(oct).balanceOf(dave);
        IDesk(desk).inherit(alice);
        assertEq(IERC20L(oct).balanceOf(carol) - cO, 700e18); assertEq(IERC20L(oct).balanceOf(dave) - dO, 300e18);
        assertEq(IERC20D(usde).balanceOf(carol), 700e18); assertEq(IERC20D(usde).balanceOf(dave), 300e18);
        assertEq(IDesk(desk).positionOf(alice), 0);
        vm.expectRevert("LiquidityDesk: no position"); IDesk(desk).inherit(alice);
    }
}
