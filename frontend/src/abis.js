import { parseAbi } from 'viem';

export const troveManagerAbi = parseAbi([
  'function getEntireDebtAndColl(address) view returns (uint256 debt, uint256 coll, uint256 pendingDebt, uint256 pendingColl)',
  'function getTroveStatus(address) view returns (uint256)',
  'function getCurrentICR(address, uint256) view returns (uint256)',
  'function getNominalICR(address) view returns (uint256)',
  'function getEntireSystemDebt() view returns (uint256)',
  'function getEntireSystemColl() view returns (uint256)',
  'function getTCR(uint256) view returns (uint256)',
  'function checkRecoveryMode(uint256) view returns (bool)',
  'function getBorrowingRateWithDecay() view returns (uint256)',
  'function getRedemptionRateWithDecay() view returns (uint256)',
  'function baseRate() view returns (uint256)',
  'function currentRateIndex() view returns (uint256)',
  'function getTroveOwnersCount() view returns (uint256)',
  'function MCR() view returns (uint256)',
  'function redeemCollateral(uint256, address, address, address, uint256, uint256, uint256)',
  'function liquidate(address)',
  'function batchLiquidateTroves(address[])',
  'function accrueInterest()',
]);

export const borrowerOperationsAbi = parseAbi([
  'function openTrove(uint256 maxFee, uint256 octAmount, address upperHint, address lowerHint, uint256 collAmount)',
  'function adjustTrove(uint256 maxFee, uint256 collWithdrawal, uint256 debtChange, bool isDebtIncrease, address upperHint, address lowerHint, uint256 collDeposit)',
  'function addCollateralFor(address owner, address upperHint, address lowerHint, uint256 collAmount)',
  'function setAutoRepay(uint8 cadence)',
  'function skimYield(address owner, address upperHint, address lowerHint)',
  'function autoRepay(address owner) view returns (uint8 cadence, uint64 lastSkim, uint256 baseline)',
  'function closeTrove()',
  'function claimCollateral()',
]);

export const stabilityPoolAbi = parseAbi([
  'function provideToSP(uint256)',
  'function withdrawFromSP(uint256)',
  'function withdrawETHGainToTrove(address, address)',
  'function getCompoundedLUSDDeposit(address) view returns (uint256)',
  'function getDepositorETHGain(address) view returns (uint256)',
  'function getTotalLUSDDeposits() view returns (uint256)',
  'function getETH() view returns (uint256)',
]);

export const priceFeedAbi = parseAbi([
  'function peek() view returns (uint256 price, bool healthy)',
  'function lastGoodPrice() view returns (uint256)',
  'function isReduceOnly() view returns (bool)',
  'function isWindDown() view returns (bool)',
  'function lowerOfMarket(uint256) view returns (uint256)',
  'function lastGoodTimestamp() view returns (uint256)',
  'function fetchPrice() returns (uint256)',
]);

export const bufferAbi = parseAbi([
  'function pot() view returns (uint256)',
  'function inventory() view returns (uint256)',
  'function potValue(uint256) view returns (uint256)',
  'function target() view returns (uint256)',
  'function circulatingSupply() view returns (uint256)',
  'function debtCeiling(uint256) view returns (uint256)',
  'function redeemCapacity(uint256) view returns (uint256)',
  'function quoteInventory(uint256, uint256) view returns (uint256)',
  'function buyInventory(uint256 octAmount, uint256 maxCollIn) returns (uint256)',
  'function fill(uint256)',
  'function releaseSurplus() returns (uint256)',
  'function ownPot() view returns (uint256)',
  'function totalDeposits() view returns (uint256)',
  'function depositOf(address) view returns (uint256)',
  'function lockedUntil(address) view returns (uint256)',
  'function pointsOf(address) view returns (uint256)',
  'function releasable(uint256 price) view returns (uint256)',
  'function lastRelease() view returns (uint256)',
  'function deposit(uint256)',
  'function withdraw(uint256)',
  'function feesOf(address) view returns (uint256)',
  'function depositorsShareBps() view returns (uint256)',
  'function feesOwed() view returns (uint256)',
  'function totalFeesShared() view returns (uint256)',
  'function claimFees() returns (uint256)',
]);

export const auctionAbi = parseAbi([
  'function lot() view returns (uint256)',
  'function price() view returns (uint256)',
  'function cost() view returns (uint256)',
  'function empty() view returns (bool)',
  'function totalBurned() view returns (uint256)',
  'function totalSold() view returns (uint256)',
  'function buy(uint256 maxStack)',
]);

export const splitterAbi = parseAbi([
  'function pending() view returns (uint256)',
  'function polKeeper() view returns (address)',
]);

export const polAbi = parseAbi([
  'function octAtOrAbovePar() view returns (bool)',
  'function positionCount() view returns (uint256)',
  'function totalOctDeposited() view returns (uint256)',
  'function totalCollToAuction() view returns (uint256)',
  'function totalCollReturned() view returns (uint256)',
  'function totalOctHarvested() view returns (uint256)',
  'function failedSince() view returns (uint64)',
  'function harvest() returns (uint256)',
  'function totalOctCompounded() view returns (uint256)',
  'function protocolShare() view returns (uint256)',
  'function seedOct() view returns (uint256)',
]);

export const rewardsAbi = parseAbi([
  'function claimable(address) view returns (uint256)',
  'function claim() returns (uint256)',
]);

export const registryAbi = parseAbi([
  'function setPlan(address[] accounts, uint16[] bps, address fallbackHeir)',
  'function clearPlan()',
  'function proveLife()',
  'function getHeirs(address) view returns (address[] accounts, uint16[] bps)',
  'function getFallbackHeir(address) view returns (address)',
  'function lastProof(address) view returns (uint256)',
  'function hasPlan(address) view returns (bool)',
  'function successionState(address) view returns (uint8 state, uint256 dueAt, uint256 executableAt)',
  'function escrowOf(address heir, address token) view returns (uint256)',
  'function estateOf(address) view returns (uint256 oct, uint256 coll, bool spWithdrawn)',
  'function execute(address)',
  'function claimEscrow(address token)',
  'function PROOF_PERIOD() view returns (uint256)',
  'function RETURN_WINDOW() view returns (uint256)',
]);

export const hintHelpersAbi = parseAbi([
  'function getRedemptionHints(uint256, uint256, uint256) view returns (address firstRedemptionHint, uint256 partialRedemptionHintNICR, uint256 truncatedAmount)',
  'function getApproxHint(uint256 cr, uint256 numTrials, uint256 inputRandomSeed) view returns (address hintAddress, uint256 diff, uint256 latestRandomSeed)',
]);

export const sortedTrovesAbi = parseAbi([
  'function findInsertPosition(uint256, address, address) view returns (address, address)',
  'function getSize() view returns (uint256)',
  'function getLast() view returns (address)',
  'function getFirst() view returns (address)',
]);

export const multiTroveGetterAbi = parseAbi([
  'struct CombinedTroveData { address owner; uint256 debt; uint256 coll; uint256 stake; uint256 snapshotETH; uint256 snapshotLUSDDebt; }',
  'function getMultipleSortedTroves(int256 startIdx, uint256 count) view returns (CombinedTroveData[])',
]);

export const collSurplusPoolAbi = parseAbi([
  'function getCollateral(address) view returns (uint256)',
]);

export const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function totalSupply() view returns (uint256)',
  'function symbol() view returns (string)',
]);

export const wstAbi = parseAbi([
  'function mint(address, uint256)',
  'function stEthPerToken() view returns (uint256)',
]);

export const keeperDeskAbi = parseAbi([
  'struct Pending { uint256 price; bool oracleHealthy; bool recoveryMode; address[] liquidatable; address[] executable; address[] skimmable; uint256 octReward; uint256 collReward; bool tend; }',
  'function pending(uint256 maxScan) view returns (Pending)',
  'function run(address[] liquidate, address[] execute, address[] skim, bool tend) returns (uint256 octPaid, uint256 collPaid)',
  'function skimmable(address owner) view returns (uint256)',
]);

export const liquidityDeskAbi = parseAbi([
  'function provide(uint256 octAmount, uint256 counterAmount) returns (uint256 tokenId, uint256 octUsed, uint256 counterUsed)',
  'function collect() returns (uint256 oct, uint256 counter)',
  'function withdraw(uint128 liquidity) returns (uint256 oct, uint256 counter)',
  'function inherit(address owner)',
  'function claimEscrow(address token)',
  'function positionOf(address) view returns (uint256)',
  'function liquidityOf(address) view returns (uint128)',
  'function owedOf(address) view returns (uint256 oct, uint256 counter)',
  'function atPar() view returns (bool)',
  'function totalOctProvided() view returns (uint256)',
  'function totalCounterProvided() view returns (uint256)',
  'function escrowOf(address, address) view returns (uint256)',
]);

export const uniswapPoolAbi = parseAbi([
  'function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)',
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function liquidity() view returns (uint128)',
]);

export const aggregatorAbi = parseAbi([
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
  'function decimals() view returns (uint8)',
]);
