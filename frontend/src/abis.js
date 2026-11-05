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
  'function redeemCollateral(uint256, address, address, address, uint256, uint256, uint256)',
  'function liquidate(address)',
  'function batchLiquidateTroves(address[])',
  'function accrueInterest()',
]);

export const borrowerOperationsAbi = parseAbi([
  'function openTrove(uint256 maxFee, uint256 octAmount, address upperHint, address lowerHint, uint256 collAmount)',
  'function adjustTrove(uint256 maxFee, uint256 collWithdrawal, uint256 debtChange, bool isDebtIncrease, address upperHint, address lowerHint, uint256 collDeposit)',
  'function operatorAdjustTrove(address owner, uint256 maxFee, uint256 collWithdrawal, uint256 debtChange, bool isDebtIncrease, address upperHint, address lowerHint, uint256 collDeposit)',
  'function closeTrove()',
  'function claimCollateral()',
]);

export const stabilityPoolAbi = parseAbi([
  'function provideToSP(uint256, address)',
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
]);

export const registryAbi = parseAbi([
  'function setPlan(address[] accounts, uint16[] bps, address fallbackHeir)',
  'function clearPlan()',
  'function proveLife()',
  'function setOperator(address operator, bool active, bool mayBorrow, uint256 crFloor)',
  'function getHeirs(address) view returns (address[] accounts, uint16[] bps)',
  'function getFallbackHeir(address) view returns (address)',
  'function lastProof(address) view returns (uint256)',
  'function hasPlan(address) view returns (bool)',
  'function successionState(address) view returns (uint8 state, uint256 dueAt, uint256 executableAt)',
  'function getOperator(address, address) view returns (bool active, bool mayBorrow, uint256 crFloor)',
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
