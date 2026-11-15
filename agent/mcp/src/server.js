#!/usr/bin/env node
// LegacyStack MCP server: read-only protocol data and unsigned transaction builders for agents.
// The owner signs. This server holds no keys, sends no transactions and takes no approvals.
//
// Run: node src/server.js            (stdio transport; add it to an MCP client's config)
// Env: LEGACYSTACK_RPC (default: a public Sepolia node), LEGACYSTACK_DEPLOYMENT (a URL or a path to deployment.json;
//      default: the site's deployment.json), LEGACYSTACK_SITE (default https://plslend.github.io/legacystack-core/)
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { createPublicClient, http, encodeFunctionData, formatEther, parseEther, isAddress, getAddress } from 'viem';
import { readFileSync } from 'node:fs';
import * as A from '../../../frontend/src/abis.js';

const SITE = process.env.LEGACYSTACK_SITE || 'https://plslend.github.io/legacystack-core/';
const RPC = process.env.LEGACYSTACK_RPC || 'https://ethereum-sepolia-rpc.publicnode.com';
const WAD = 10n ** 18n;
const ZERO = '0x0000000000000000000000000000000000000000';

let D = null; // the deployment
async function deployment() {
  if (D) return D;
  const src = process.env.LEGACYSTACK_DEPLOYMENT || SITE + 'deployment.json';
  if (/^https?:/.test(src)) { const r = await fetch(src, { cache: 'no-store' }); if (!r.ok) throw new Error('deployment.json ' + r.status); D = await r.json(); }
  else D = JSON.parse(readFileSync(src, 'utf8'));
  return D;
}
const client = createPublicClient({ transport: http(RPC) });
const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args });
const fmt = (x, d = 4) => Number(formatEther(x)).toLocaleString('en-US', { maximumFractionDigits: d });
const pct = (wad) => (Number(wad) / 1e16).toFixed(1) + '%';
const date = (ts) => (ts === 0n ? 'never' : new Date(Number(ts) * 1000).toISOString().slice(0, 10));
const isZero = (a) => !a || a.toLowerCase() === ZERO;
const addr = (a) => { if (!isAddress(a)) throw new Error('not an address: ' + a); return getAddress(a); };
const text = (s) => ({ content: [{ type: 'text', text: typeof s === 'string' ? s : JSON.stringify(s, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2) }] });

const DEFINITION = 'LegacyStack is an immutable borrowing protocol on Ethereum: a fixed 1.5% a year credit line against staked ether (wstETH), with succession built into the vault. No admin keys, no governance over positions, no middleman. OCT is its loan unit (never a stablecoin).';
const RISKS = [
  'Liquidation under a 110% collateral ratio: no margin call, no cure period, no support line. Keep a wide margin (200% or more for a position meant to last years).',
  'Redemptions when OCT trades below a dollar: the reserve serves first, then the lowest-ratio vaults, whose debt and collateral shrink by the same value.',
  'Oracle: a degraded feed pauses new borrowing; thirty days without any feed is a permanent wind-down; repaying, adding collateral and closing are never blocked.',
  'Immutable code cannot be patched. Unaudited while the site says so.',
  'Succession is final: a year without the proof-of-life button plus thirty days settles the estate to the named addresses.',
  'The frontend does not serve persons in the United States.',
];

const server = new McpServer({ name: 'legacystack', version: '0.1.0' });

server.registerTool('protocol_overview', {
  title: 'What LegacyStack is',
  description: 'The canonical definition, the invariants, the risks in order, the deployment in use and where the full brief lives. Read this before anything else.',
  inputSchema: {},
}, async () => {
  const d = await deployment();
  return text({
    definition: DEFINITION,
    status: d.chainId === 11155111 ? 'Sepolia test deployment of unaudited code; nothing here has value' : 'see agent.md',
    invariants: ['no admin keys, no owner, no proxy, no upgrade path', 'interest fixed at 1.5% a year', 'minimum collateral ratio 110%', 'collateral is never lent out or rehypothecated', 'the oracle is Chainlink ETH/USD times Lido stEthPerToken(), never a pool', 'revenue never leaves the protocol'],
    risks: RISKS,
    chainId: d.chainId,
    addresses: d,
    brief: SITE + 'agent.md', machine: SITE + '.well-known/legacystack.json', playbook: SITE + 'playbook.html', auditMap: SITE + 'CHANGES_FROM_UPSTREAM.md',
    note: 'Take contract addresses only from the deployment above. Simulate every transaction. The owner signs.',
  });
});

server.registerTool('protocol_state', {
  title: 'Live protocol numbers',
  description: 'Price and oracle health, system collateral and debt, total collateral ratio, recovery mode, fees, the reserve (pot, target, inventory, ceiling), the Stability Pool, the protocol-owned liquidity against its target.',
  inputSchema: {},
}, async () => {
  const d = await deployment();
  const [price, healthy] = await read(d.priceFeed, A.priceFeedAbi, 'peek');
  const [debt, coll, mintFee, redFee, index] = await Promise.all([
    read(d.troveManager, A.troveManagerAbi, 'getEntireSystemDebt'), read(d.troveManager, A.troveManagerAbi, 'getEntireSystemColl'),
    read(d.troveManager, A.troveManagerAbi, 'getBorrowingRateWithDecay'), read(d.troveManager, A.troveManagerAbi, 'getRedemptionRateWithDecay'), read(d.troveManager, A.troveManagerAbi, 'currentRateIndex'),
  ]);
  const [tcr, recovery, pot, target, inventory, ceiling, spTotal] = await Promise.all([
    read(d.troveManager, A.troveManagerAbi, 'getTCR', [price]), read(d.troveManager, A.troveManagerAbi, 'checkRecoveryMode', [price]),
    read(d.redemptionBuffer, A.bufferAbi, 'pot'), read(d.redemptionBuffer, A.bufferAbi, 'target'), read(d.redemptionBuffer, A.bufferAbi, 'inventory'),
    read(d.redemptionBuffer, A.bufferAbi, 'debtCeiling', [price]), read(d.stabilityPool, A.stabilityPoolAbi, 'getTotalLUSDDeposits'),
  ]);
  const out = {
    price: { wstETHUSD: fmt(price, 2), oracleHealthy: healthy },
    system: { collateralWstETH: fmt(coll), debtOCT: fmt(debt, 0), totalCollateralRatio: pct(tcr), recoveryMode: recovery, rateIndex: formatEther(index) },
    fees: { mintFeeNow: pct(mintFee), redemptionFeeNow: pct(redFee), interestPerYear: '1.5% fixed' },
    reserve: { potWstETH: fmt(pot), potUSD: fmt((pot * price) / WAD, 0), targetUSD: fmt(target, 0), inventoryOCT: fmt(inventory, 0), debtCeilingOCT: fmt(ceiling, 0) },
    stabilityPool: { totalOCT: fmt(spTotal, 0) },
  };
  if (!isZero(d.polKeeper) && d.polKeeper.toLowerCase() !== (d.burnAuction || '').toLowerCase()) {
    try {
      const [value, tgt, below, ff] = await Promise.all([read(d.polKeeper, A.polAbi, 'polValue'), read(d.polKeeper, A.polAbi, 'polTarget'), read(d.polKeeper, A.polAbi, 'belowTarget'), read(d.polKeeper, A.polAbi, 'freeFloat')]);
      out.protocolOwnedLiquidity = { valueOCT: fmt(value, 0), targetOCT: fmt(tgt, 0), freeFloatOCT: fmt(ff, 0), belowTarget: below, rule: below ? 'pool fees compound and the whole reserve surplus feeds the pool' : 'pool fees go to the reserve and the surplus is split with the burn auction' };
    } catch {}
  }
  return text(out);
});

server.registerTool('vault', {
  title: 'A wallet\'s vault and plan',
  description: 'Collateral, debt, ratio, liquidation price, auto-repay setting and skimmable yield, Stability Pool and reserve deposits, protocol liquidity, and the succession plan state for one owner address.',
  inputSchema: { owner: z.string().describe('the owner address (0x...)') },
}, async ({ owner }) => {
  const d = await deployment(); const o = addr(owner);
  const [price] = await read(d.priceFeed, A.priceFeedAbi, 'peek');
  const [status, [debt, coll], [cadence, lastSkim], spDep, spGain, rdDep, inherited] = await Promise.all([
    read(d.troveManager, A.troveManagerAbi, 'getTroveStatus', [o]), read(d.troveManager, A.troveManagerAbi, 'getEntireDebtAndColl', [o]),
    read(d.borrowerOperations, A.borrowerOperationsAbi, 'autoRepay', [o]),
    read(d.stabilityPool, A.stabilityPoolAbi, 'getCompoundedLUSDDeposit', [o]), read(d.stabilityPool, A.stabilityPoolAbi, 'getDepositorETHGain', [o]),
    read(d.redemptionBuffer, A.bufferAbi, 'depositOf', [o]), read(d.redemptionBuffer, A.bufferAbi, 'inheritedOf', [o]).catch(() => 0n),
  ]);
  const open = status === 1n;
  const out = { owner: o, vault: open ? {
    collateralWstETH: fmt(coll), debtOCT: fmt(debt, 2), collateralRatio: coll > 0n && debt > 0n ? pct((coll * price) / debt) : 'n/a',
    liquidationPriceUSD: coll > 0n ? fmt((debt * 11n * WAD) / (coll * 10n), 2) : 'n/a',
    autoRepay: ['off', 'monthly', 'quarterly', 'yearly'][Number(cadence)] || 'off', lastSkim: date(lastSkim),
  } : 'no open vault' };
  if (open && !isZero(d.keeperDesk)) { try { out.vault.skimmableYieldWstETH = fmt(await read(d.keeperDesk, A.keeperDeskAbi, 'skimmable', [o])); } catch {} }
  out.stabilityPool = { depositOCT: fmt(spDep, 2), wstETHGain: fmt(spGain) };
  out.reserve = { depositWstETH: fmt(rdDep), inheritedWaitingWstETH: fmt(inherited) };
  if (!isZero(d.liquidityDesk)) { try { const [tokenId, [oOct, oUsde]] = await Promise.all([read(d.liquidityDesk, A.liquidityDeskAbi, 'positionOf', [o]), read(d.liquidityDesk, A.liquidityDeskAbi, 'owedOf', [o])]); out.liquidity = tokenId === 0n ? 'none' : { positionId: tokenId.toString(), feesOwedOCT: fmt(oOct, 2), feesOwedUSDe: fmt(oUsde, 2) }; } catch {} }
  const [has, [state, dueAt, executableAt], last] = await Promise.all([read(d.successionRegistry, A.registryAbi, 'hasPlan', [o]), read(d.successionRegistry, A.registryAbi, 'successionState', [o]), read(d.successionRegistry, A.registryAbi, 'lastProof', [o])]);
  if (has) {
    const [[heirs, bps], fallback] = await Promise.all([read(d.successionRegistry, A.registryAbi, 'getHeirs', [o]), read(d.successionRegistry, A.registryAbi, 'getFallbackHeir', [o])]);
    out.plan = { state: ['none', 'alive', 'due', 'executable', 'executed'][Number(state)] || String(state), lastProofOfLife: date(last), nextProofDue: date(dueAt), executableFrom: date(executableAt), heirs: heirs.map((h, i) => ({ address: h, sharePercent: Number(bps[i]) / 100 })), fallbackHeir: isZero(fallback) ? 'none' : fallback };
  } else out.plan = 'no plan: nothing passes on; the owner should set one';
  return text(out);
});

server.registerTool('quote_open', {
  title: 'Quote a new vault',
  description: 'For an amount of wstETH and a target collateral ratio: the OCT that can be borrowed, the mint fee, what the borrower receives, the liquidation price and the yearly interest. Reads the current price and fee; nothing is sent.',
  inputSchema: { collateralWstETH: z.string().describe('wstETH to deposit, e.g. "10"'), targetRatioPercent: z.number().min(110).default(200).describe('the collateral ratio to open at, in percent (200 or more is prudent for a long position)') },
}, async ({ collateralWstETH, targetRatioPercent }) => {
  const d = await deployment(); const coll = parseEther(collateralWstETH);
  const [[price, healthy], mintFee, mcr] = await Promise.all([read(d.priceFeed, A.priceFeedAbi, 'peek'), read(d.troveManager, A.troveManagerAbi, 'getBorrowingRateWithDecay'), read(d.troveManager, A.troveManagerAbi, 'MCR')]);
  const ratio = BigInt(Math.round(targetRatioPercent * 100)) * WAD / 10000n;
  const gas = 200n * WAD;
  // total debt D so that coll*price/D = ratio; the borrowed OCT = (D - gas) / (1 + fee)
  const totalDebt = (coll * price) / ratio;
  const borrowed = ((totalDebt - gas) * WAD) / (WAD + mintFee);
  if (borrowed <= 0n) return text({ error: 'too little collateral for that ratio' });
  const fee = (borrowed * mintFee) / WAD;
  const liq = ((borrowed + fee + gas) * mcr) / coll;
  return text({
    priceUsed: fmt(price, 2), oracleHealthy: healthy, collateralWstETH, targetRatio: targetRatioPercent + '%',
    borrowOCT: fmt(borrowed, 2), mintFee: pct(mintFee) + ' = ' + fmt(fee, 2) + ' OCT (to the reserve)', parkedCompensationOCT: '200 (returned at close)',
    receivedOCT: fmt(borrowed, 2), totalDebtOCT: fmt(borrowed + fee + gas, 2), liquidationPriceUSD: fmt(liq, 2), fallToLiquidation: (100 - Number(liq) / Number(price) * 100).toFixed(1) + '%',
    interestPerYearOCT: fmt((borrowed + fee + gas) * 15n / 1000n, 2),
    minimumDebtOCT: '1800', note: borrowed < 1800n * WAD ? 'below the 1,800 OCT minimum: open with more collateral or a lower ratio' : 'ok',
  });
});

server.registerTool('keeper_pending', {
  title: 'Housekeeping due',
  description: 'What the keeper desk would do right now: vaults to liquidate, estates to settle, vaults to auto-repay, inherited payouts to finish, reserve housekeeping, and the reward paid to whoever presses.',
  inputSchema: { maxScan: z.number().int().min(1).max(200).default(60) },
}, async ({ maxScan }) => {
  const d = await deployment();
  if (isZero(d.keeperDesk)) return text('no keeper desk on this chain');
  const w = await read(d.keeperDesk, A.keeperDeskAbi, 'pending', [BigInt(maxScan)]);
  return text({ price: fmt(w.price, 2), oracleHealthy: w.oracleHealthy, recoveryMode: w.recoveryMode, liquidatable: w.liquidatable, estatesToSettle: w.executable, autoRepayDue: w.skimmable, inheritedPayoutsToFinish: (w.payouts ?? 0n).toString(), reserveHousekeeping: w.tend, rewardIfRunNow: { oct: fmt(w.octReward, 2), wstETH: fmt(w.collReward) } });
});

const cadences = { off: 0, monthly: 1, quarterly: 2, yearly: 3 };
server.registerTool('build_tx', {
  title: 'Build an unsigned transaction',
  description: 'Returns {to, data, value} for one protocol action, for the owner\'s wallet to simulate and sign. Actions: approve_wst (collateral allowance), open_vault, add_collateral, repay, close_vault, set_auto_repay, set_plan, prove_life, provide_to_stability_pool, withdraw_from_stability_pool, reserve_deposit, finish_inherited_payout. Never sends anything.',
  inputSchema: {
    action: z.enum(['approve_wst', 'open_vault', 'add_collateral', 'repay', 'close_vault', 'set_auto_repay', 'set_plan', 'prove_life', 'provide_to_stability_pool', 'withdraw_from_stability_pool', 'reserve_deposit', 'finish_inherited_payout']),
    amount: z.string().optional().describe('wstETH or OCT amount as a decimal string, where the action takes one'),
    borrowOCT: z.string().optional().describe('open_vault: OCT to borrow'),
    maxFeePercent: z.number().optional().describe('open_vault: the highest mint fee accepted, default 1'),
    cadence: z.enum(['off', 'monthly', 'quarterly', 'yearly']).optional(),
    heirs: z.array(z.object({ address: z.string(), sharePercent: z.number() })).optional(),
    fallbackHeir: z.string().optional(),
    owner: z.string().optional().describe('add_collateral: the vault to add to (any vault); finish_inherited_payout: the heir'),
  },
}, async (p) => {
  const d = await deployment();
  const tx = (to, abi, functionName, args = []) => ({ to, data: encodeFunctionData({ abi, functionName, args }), value: '0', note: 'simulate before signing; the owner signs' });
  switch (p.action) {
    case 'approve_wst': return text(tx(d.wstETH, A.erc20Abi, 'approve', [d.borrowerOperations, parseEther(p.amount || '0')]));
    case 'open_vault': {
      const maxFee = BigInt(Math.round((p.maxFeePercent ?? 1) * 100)) * WAD / 10000n;
      return text({ steps: ['approve_wst for the collateral (BorrowerOperations as spender)', 'open_vault'], ...tx(d.borrowerOperations, A.borrowerOperationsAbi, 'openTrove', [maxFee, parseEther(p.borrowOCT || '0'), ZERO, ZERO, parseEther(p.amount || '0')]) });
    }
    case 'add_collateral': return text({ steps: ['approve_wst', 'add_collateral'], ...tx(d.borrowerOperations, A.borrowerOperationsAbi, 'addCollateralFor', [addr(p.owner), ZERO, ZERO, parseEther(p.amount || '0')]) });
    case 'repay': return text(tx(d.borrowerOperations, A.borrowerOperationsAbi, 'adjustTrove', [0n, 0n, parseEther(p.amount || '0'), false, ZERO, ZERO, 0n]));
    case 'close_vault': return text(tx(d.borrowerOperations, A.borrowerOperationsAbi, 'closeTrove'));
    case 'set_auto_repay': return text(tx(d.borrowerOperations, A.borrowerOperationsAbi, 'setAutoRepay', [cadences[p.cadence || 'off']]));
    case 'set_plan': {
      const heirs = p.heirs || []; const total = heirs.reduce((s, h) => s + h.sharePercent, 0);
      if (!heirs.length || Math.abs(total - 100) > 1e-9) return text({ error: 'heirs must add up to 100 percent' });
      return text(tx(d.successionRegistry, A.registryAbi, 'setPlan', [heirs.map((h) => addr(h.address)), heirs.map((h) => Math.round(h.sharePercent * 100)), p.fallbackHeir ? addr(p.fallbackHeir) : ZERO]));
    }
    case 'prove_life': return text(tx(d.successionRegistry, A.registryAbi, 'proveLife'));
    case 'provide_to_stability_pool': return text(tx(d.stabilityPool, A.stabilityPoolAbi, 'provideToSP', [parseEther(p.amount || '0')]));
    case 'withdraw_from_stability_pool': return text(tx(d.stabilityPool, A.stabilityPoolAbi, 'withdrawFromSP', [parseEther(p.amount || '0')]));
    case 'reserve_deposit': return text({ steps: ['approve wstETH for the RedemptionBuffer', 'reserve_deposit'], ...tx(d.redemptionBuffer, A.bufferAbi, 'deposit', [parseEther(p.amount || '0')]) });
    case 'finish_inherited_payout': return text(tx(d.redemptionBuffer, A.bufferAbi, 'finishPayout', [addr(p.owner)]));
    default: return text({ error: 'unknown action' });
  }
});

server.registerResource('brief', SITE + 'agent.md', { title: 'LegacyStack protocol brief', mimeType: 'text/markdown' }, async (uri) => {
  const r = await fetch(uri.href, { cache: 'no-store' }); return { contents: [{ uri: uri.href, mimeType: 'text/markdown', text: await r.text() }] };
});

const transport = new StdioServerTransport();
await server.connect(transport);
