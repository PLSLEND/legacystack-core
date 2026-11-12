import { createPublicClient, createWalletClient, custom, http, formatUnits, parseUnits, getAddress, isAddress, zeroAddress, defineChain, BaseError, ContractFunctionRevertedError } from 'viem';
import { sepolia } from 'viem/chains';
import * as A from './abis.js';

// ---------- configuration ----------
const DEPLOYMENT_URL = 'deployment.json';
const CHAINS = {
  11155111: { chain: sepolia, rpc: 'https://ethereum-sepolia-rpc.publicnode.com', explorer: 'https://sepolia.etherscan.io', name: 'Sepolia', uniswap: 'sepolia' },
  31337: { chain: defineChain({ id: 31337, name: 'Local', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } } }), rpc: 'http://127.0.0.1:8545', explorer: '', name: 'local chain', uniswap: '' },
};
const WAD = 10n ** 18n;
const MCR = 11n * 10n ** 17n;
const GAS_COMP = 200n * WAD;
const MIN_NET_DEBT = 1800n * WAD;
const MAX_FEE = 5n * 10n ** 16n; // the protocol's own cap on the mint fee (5%)
const Q96 = 2n ** 96n;

let D = null;           // deployment addresses
let NET = null;         // chain config
let pub = null;         // public client
let wallet = null;      // wallet client
let me = null;          // connected address
let price = 0n; let healthy = true;
let refreshTimer = null;
let heirRowCount = 0;
let allTroves = [];     // the sorted list, riskiest first, for "debt in front of you"
let desk = null;        // last Keeper desk read
let hasVault = false; let hasPlan = false;
const bal = { eth: 0n, wst: 0n, oct: 0n, coll: 0n, debt: 0n, spDep: 0n, rdDep: 0n, inv: 0n };   // what the Max buttons read
let isZero = (a) => !a || a === zeroAddress;

// ---------- helpers ----------
const $ = (id) => document.getElementById(id);
const fmt = (v, digits = 2, unit = '') => {
  if (v === null || v === undefined) return '—';
  const n = Number(formatUnits(v, 18));
  const s = n.toLocaleString('en-US', { maximumFractionDigits: digits, minimumFractionDigits: 0 });
  return unit ? `${s} ${unit}` : s;
};
const pct = (ratioWad) => {
  if (ratioWad === null || ratioWad === undefined) return '—';
  if (ratioWad > 10n ** 30n) return '∞';
  return `${(Number(ratioWad) / 1e16).toLocaleString('en-US', { maximumFractionDigits: 1 })}%`;
};
const short = (a) => a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—';
const date = (ts) => ts ? new Date(Number(ts) * 1000).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' }) : '—';
const toWad = (s) => { const t = (s || '').trim(); return t ? parseUnits(t, 18) : 0n; };
const addr = (s) => getAddress(s.trim().toLowerCase());          // any casing is accepted; the checksum is recomputed
const looksLikeAddress = (s) => isAddress((s || '').trim(), { strict: false });
const icrOf = (coll, debt) => debt === 0n ? 0n : (coll * price) / debt;
const liqPrice = (coll, debt) => coll === 0n ? 0n : (debt * MCR) / coll;
const usd = (wad, digits = 0) => `$${fmt(wad, digits)}`;

function toast(msg, kind = '') {
  const t = $('toast'); t.textContent = msg; t.className = `toast ${kind}`;
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.add('hidden'), 7000);
}
function explain(err) {
  let reason = '';
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (rev && rev.reason) reason = rev.reason;
    else if (err.shortMessage) reason = err.shortMessage;
  }
  if (!reason) reason = (err && err.message) ? err.message.split('\n')[0] : String(err);
  // the contracts speak in plain sentences; strip their prefixes
  return reason.replace(/^(BorrowerOps|TroveManager|TM|StabilityPool|RedemptionBuffer|SuccessionRegistry|KeeperDesk|LUSD|PriceFeed): /, '');
}
async function send(label, fn) {
  if (!wallet || !me) { toast('Connect a wallet first.', 'bad'); return null; }
  try {
    toast(`${label}: confirm in your wallet…`);
    const hash = await fn();
    toast(`${label}: sent, waiting for the block…`);
    const rc = await pub.waitForTransactionReceipt({ hash });
    if (rc.status !== 'success') { toast(`${label}: the transaction reverted.`, 'bad'); return null; }
    toast(`${label}: done.`, 'ok');
    await refresh();
    return rc;
  } catch (e) {
    console.error(e);
    toast(`${label}: ${explain(e)}`, 'bad');
    return null;
  }
}
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const write = (address, abi, functionName, args = []) => wallet.writeContract({ address, abi, functionName, args, account: me, chain: NET.chain });
// Calls that wrap inner calls in try/catch (the Keeper desk, the POL keeper) fool gas estimation: an inner
// call that runs out of gas is caught and the estimate comes back too low. Pad the estimate for those.
const writePadded = async (address, abi, functionName, args = []) => {
  const est = await pub.estimateContractGas({ address, abi, functionName, args, account: me });
  return wallet.writeContract({ address, abi, functionName, args, account: me, chain: NET.chain, gas: (est * 3n) / 2n + 200000n });
};

// ---------- hints ----------
async function insertHints(nicr) {
  const size = await read(D.sortedTroves, A.sortedTrovesAbi, 'getSize');
  const trials = BigInt(Math.max(15, Math.ceil(15 * Math.sqrt(Number(size)))));
  const seed = BigInt(Math.floor(Math.random() * 1e9));
  const [approx] = await read(D.hintHelpers, A.hintHelpersAbi, 'getApproxHint', [nicr, trials, seed]);
  const [upper, lower] = await read(D.sortedTroves, A.sortedTrovesAbi, 'findInsertPosition', [nicr, approx, approx]);
  return [upper, lower];
}
const nominalCR = (coll, debt) => debt === 0n ? 2n ** 255n : (coll * 10n ** 20n) / debt;

// ---------- wallet ----------
async function connect() {
  if (!window.ethereum) { toast('No wallet found. Install MetaMask or Rabby and reload.', 'bad'); return; }
  try {
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    me = getAddress(accounts[0]);
    wallet = createWalletClient({ chain: NET.chain, transport: custom(window.ethereum) });
    const chainIdHex = await window.ethereum.request({ method: 'eth_chainId' });
    if (parseInt(chainIdHex, 16) !== D.chainId) { await switchNetwork(); }
    $('btn-connect').textContent = short(me);
    window.ethereum.on?.('accountsChanged', () => location.reload());
    window.ethereum.on?.('chainChanged', () => location.reload());
    await refresh();
  } catch (e) { toast(explain(e), 'bad'); }
}
async function switchNetwork() {
  const hex = '0x' + D.chainId.toString(16);
  try {
    await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] });
  } catch (e) {
    if (e.code === 4902 || /Unrecognized|not added/i.test(e.message || '')) {
      await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [{ chainId: hex, chainName: `LegacyStack ${NET.name}`, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: [NET.rpc], blockExplorerUrls: NET.explorer ? [NET.explorer] : [] }] });
    } else { throw e; }
  }
}
async function networkBadge() {
  const b = $('net-badge');
  if (!me) { b.textContent = `${NET.name} · read-only`; b.className = 'badge badge-muted'; return; }
  const chainIdHex = await window.ethereum.request({ method: 'eth_chainId' });
  const ok = parseInt(chainIdHex, 16) === D.chainId;
  b.textContent = ok ? `${NET.name} · ${short(me)}` : `wrong network, switch to ${NET.name}`;
  b.className = ok ? 'badge badge-ok' : 'badge badge-bad';
}

// ---------- refresh ----------
async function refresh() {
  try {
    [price, healthy] = await read(D.priceFeed, A.priceFeedAbi, 'peek');
    $('s-price').textContent = usd(price);
    const [reduceOnly, windDown, borrowPrice] = await Promise.all([
      read(D.priceFeed, A.priceFeedAbi, 'isReduceOnly'), read(D.priceFeed, A.priceFeedAbi, 'isWindDown').catch(() => false), read(D.priceFeed, A.priceFeedAbi, 'lowerOfMarket', [price]).catch(() => price),
    ]);
    $('s-oracle').textContent = windDown ? 'wind-down · this deployment lends no more' : healthy && !reduceOnly ? (borrowPrice < price ? `healthy · borrowing priced at ${usd(borrowPrice)} (stETH market discount)` : 'healthy') : 'degraded · reduce-only';
    $('s-oracle').style.color = healthy && !reduceOnly ? 'var(--ok)' : 'var(--warn)';
    await refreshSystem();
    await Promise.all([refreshBuffer(), refreshPoolAndVault(), refreshSuccession(), refreshDesk(), refreshMarket(), refreshDeposit(), networkBadge()]);
    await refreshFlow();
  } catch (e) { console.error(e); toast(`Could not read the chain: ${explain(e)}`, 'bad'); }
}

async function refreshSystem() {
  const [coll, debt, count, mintFee, redFee, index] = await Promise.all([
    read(D.troveManager, A.troveManagerAbi, 'getEntireSystemColl'),
    read(D.troveManager, A.troveManagerAbi, 'getEntireSystemDebt'),
    read(D.troveManager, A.troveManagerAbi, 'getTroveOwnersCount'),
    read(D.troveManager, A.troveManagerAbi, 'getBorrowingRateWithDecay'),
    read(D.troveManager, A.troveManagerAbi, 'getRedemptionRateWithDecay'),
    read(D.troveManager, A.troveManagerAbi, 'currentRateIndex'),
  ]);
  $('y-coll').textContent = `${fmt(coll, 2, 'wstETH')} (${usd((coll * price) / WAD)})`;
  $('y-debt').textContent = fmt(debt, 0, 'OCT');
  $('y-tcr').textContent = pct(icrOf(coll, debt));
  $('y-count').textContent = count.toString();
  $('y-mintfee').textContent = pct(mintFee);
  $('y-redfee').textContent = pct(redFee);
  $('y-index').textContent = `${Number(formatUnits(index, 18)).toFixed(6)} (1 OCT borrowed at launch owes this much now)`;
  // Chainlink leg of the price
  try {
    const [, answer] = await read(D.ethUsdAggregator, A.aggregatorAbi, 'latestRoundData');
    const dec = await read(D.ethUsdAggregator, A.aggregatorAbi, 'decimals');
    $('y-eth').textContent = `$${Number(formatUnits(answer, dec)).toLocaleString('en-US', { maximumFractionDigits: 2 })}`;
  } catch { $('y-eth').textContent = '—'; }
  // the whole sorted list (riskiest first); the testnet book is small, a production page would page it
  const n = Number(count);
  allTroves = n ? await read(D.multiTroveGetter, A.multiTroveGetterAbi, 'getMultipleSortedTroves', [-1n, BigInt(Math.min(n, 200))]) : [];
  const risky = allTroves.filter((r) => icrOf(r.coll, r.debt) < 12n * 10n ** 17n).length;
  $('y-risky').textContent = String(risky);
  $('y-lowest').textContent = allTroves.length ? pct(icrOf(allTroves[0].coll, allTroves[0].debt)) : '—';
  const tb = $('trove-table').querySelector('tbody'); tb.innerHTML = '';
  for (const r of allTroves.slice(0, 12)) {
    const icr = icrOf(r.coll, r.debt);
    const liquidatable = icr < MCR;
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${short(r.owner)}</td><td>${fmt(r.coll, 3)}</td><td>${fmt(r.debt, 0)}</td><td class="${liquidatable ? 'risk' : ''}">${pct(icr)}</td><td>${liquidatable ? `<button class="btn btn-small" data-liq="${r.owner}">Liquidate</button>` : ''}</td>`;
    tb.appendChild(tr);
  }
  tb.querySelectorAll('button[data-liq]').forEach((b) => b.addEventListener('click', () => send('Liquidate', () => write(D.troveManager, A.troveManagerAbi, 'liquidate', [b.dataset.liq]))));
}

async function refreshBuffer() {
  const [pot, inv, target, ceiling, cap, circ, debt] = await Promise.all([
    read(D.redemptionBuffer, A.bufferAbi, 'pot'), read(D.redemptionBuffer, A.bufferAbi, 'inventory'),
    read(D.redemptionBuffer, A.bufferAbi, 'target'), read(D.redemptionBuffer, A.bufferAbi, 'debtCeiling', [price]),
    read(D.redemptionBuffer, A.bufferAbi, 'redeemCapacity', [price]), read(D.redemptionBuffer, A.bufferAbi, 'circulatingSupply'),
    read(D.troveManager, A.troveManagerAbi, 'getEntireSystemDebt'),
  ]);
  const potUsd = (pot * price) / WAD;
  const filled = target > 0n ? (potUsd * 100n) / target : 0n;
  $('b-pot').textContent = `${fmt(pot, 3)} wstETH (${usd(potUsd)}, ${filled}% of target)`;
  $('b-target').textContent = `${usd(target)} (15% of ${fmt(circ, 0)} OCT)`;
  $('b-inv').textContent = `${fmt(inv, 2)} OCT`; bal.inv = inv;
  $('b-ceiling').textContent = `${usd(ceiling)} · used ${fmt(debt, 0)}`;
  $('rd-preview').textContent = `The reserve can serve ${fmt(cap, 0)} OCT right now; anything above that is redeemed from the riskiest vaults.`;
  const [rel, last] = await Promise.all([read(D.redemptionBuffer, A.bufferAbi, 'releasable', [price]), read(D.redemptionBuffer, A.bufferAbi, 'lastRelease')]);
  const own = await read(D.redemptionBuffer, A.bufferAbi, 'ownPot');
  const cap5 = own / 20n; const today = rel < cap5 ? rel : cap5;
  const due = Number(last) + 86400 <= Date.now() / 1000;
  $('b-release').textContent = rel > 0n ? `${fmt(today, 4)} wstETH${due ? '' : ' (next release ' + date(Number(last) + 86400) + ')'}` : 'nothing above target';
  await refreshSinks();
}
async function refreshSinks() {
  if (isZero(D.burnAuction)) { $('au-lot').textContent = 'not deployed on this chain'; return; }
  const [lot, aPrice, burned, empty, pending, pol] = await Promise.all([
    read(D.burnAuction, A.auctionAbi, 'lot'), read(D.burnAuction, A.auctionAbi, 'price'), read(D.burnAuction, A.auctionAbi, 'totalBurned'),
    read(D.burnAuction, A.auctionAbi, 'empty'), read(D.surplusSink, A.splitterAbi, 'pending'), read(D.surplusSink, A.splitterAbi, 'polKeeper'),
  ]);
  $('au-lot').textContent = !empty && lot > 0n ? `${fmt(lot, 4)} wstETH for ${fmt((lot * aPrice) / WAD, 2)} STACK` : 'nothing yet';
  $('au-price').textContent = `${fmt(aPrice, 2)} STACK per wstETH`;
  $('au-burned').textContent = `${fmt(burned, 2)} STACK`;
  $('au-sink').textContent = pending > 0n ? `${fmt(pending, 4)} wstETH to split on the next desk run` : 'nothing';
  $('btn-buy-lot').disabled = empty || lot === 0n;
  if (pol.toLowerCase() === D.burnAuction.toLowerCase()) { $('au-pol').textContent = 'no market pool on this chain: both halves burn'; return; }
  const [par, n, octIn, toAuction, returned, harvested, failedSince, compounded, share, seed] = await Promise.all([
    read(pol, A.polAbi, 'octAtOrAbovePar'), read(pol, A.polAbi, 'positionCount'), read(pol, A.polAbi, 'totalOctDeposited'), read(pol, A.polAbi, 'totalCollToAuction').catch(() => 0n),
    read(pol, A.polAbi, 'totalCollReturned').catch(() => 0n), read(pol, A.polAbi, 'totalOctHarvested').catch(() => null), read(pol, A.polAbi, 'failedSince').catch(() => 0n),
    read(pol, A.polAbi, 'totalOctCompounded').catch(() => null), read(pol, A.polAbi, 'protocolShare').catch(() => null), read(pol, A.polAbi, 'seedOct').catch(() => 0n),
  ]);
  const held = await read(D.wstETH, A.erc20Abi, 'balanceOf', [pol]);
  const notes = [];
  if (share !== null) notes.push(`the protocol holds ${pct(share)} of the pool: fees ${share >= 5n * 10n ** 17n ? 'compound into the pool' : 'go to the reserve'}`);
  if (compounded !== null && compounded > 0n) notes.push(`${fmt(compounded, 2)} OCT of fees compounded`);
  if (harvested !== null && harvested > 0n) notes.push(`${fmt(harvested, 2)} OCT of fees to the reserve`);
  if (failedSince > 0n) notes.push(`the pool has been failing since ${date(failedSince)}; the wstETH waits, after 90 days it returns to the reserve`);
  if (returned > 0n) notes.push(`${fmt(returned, 4)} wstETH returned to the reserve after a dead spell`);
  if (toAuction > 0n) notes.push(`${fmt(toAuction, 4)} wstETH went to the auction when the pool failed`);
  $('au-pol').textContent = `${n} position${n === 1n ? '' : 's'}, ${seed > 0n ? `${fmt(seed, 0)} of opening liquidity and ` : ''}${fmt(octIn, 0)} OCT placed · ${fmt(held, 4)} wstETH waiting (${par ? 'OCT at or above par: deploys on the next run' : 'OCT below par: waiting'})${notes.length ? ' · ' + notes.join(' · ') : ''}`;
}
async function refreshDeposit() {
  if (!me) return;
  const [mine, until, pts] = await Promise.all([
    read(D.redemptionBuffer, A.bufferAbi, 'depositOf', [me]), read(D.redemptionBuffer, A.bufferAbi, 'lockedUntil', [me]), read(D.redemptionBuffer, A.bufferAbi, 'pointsOf', [me]),
  ]);
  $('rd-mine').textContent = `${fmt(mine, 4)} wstETH`; bal.rdDep = mine;
  $('rd-unlock').textContent = mine > 0n ? (Number(until) * 1000 <= Date.now() ? 'unlocked' : date(until)) : '—';
  $('rd-points').textContent = `${fmt(pts / 86400n, 3)} wstETH-days`;
  const claimable = isZero(D.reserveRewards) ? 0n : await read(D.reserveRewards, A.rewardsAbi, 'claimable', [me]);
  $('rd-claim').textContent = `${fmt(claimable, 3)} STACK`;
  $('btn-claim-stack').disabled = claimable === 0n;
}

async function refreshPoolAndVault() {
  const [total, supply, spColl] = await Promise.all([
    read(D.stabilityPool, A.stabilityPoolAbi, 'getTotalLUSDDeposits'),
    read(D.oct, A.erc20Abi, 'totalSupply'),
    read(D.stabilityPool, A.stabilityPoolAbi, 'getETH'),
  ]);
  $('sp-total').textContent = fmt(total, 0, 'OCT');
  $('sp-share').textContent = supply > 0n ? pct((total * WAD) / supply) : '—';
  $('sp-coll').textContent = fmt(spColl, 4, 'wstETH');
  if (!me) return;
  const [eth, wst, oct, status, [debt, coll], dep, gain, surplus, allowance] = await Promise.all([
    pub.getBalance({ address: me }),
    read(D.wstETH, A.erc20Abi, 'balanceOf', [me]), read(D.oct, A.erc20Abi, 'balanceOf', [me]),
    read(D.troveManager, A.troveManagerAbi, 'getTroveStatus', [me]),
    read(D.troveManager, A.troveManagerAbi, 'getEntireDebtAndColl', [me]),
    read(D.stabilityPool, A.stabilityPoolAbi, 'getCompoundedLUSDDeposit', [me]),
    read(D.stabilityPool, A.stabilityPoolAbi, 'getDepositorETHGain', [me]),
    read(D.collSurplusPool, A.collSurplusPoolAbi, 'getCollateral', [me]),
    read(D.wstETH, A.erc20Abi, 'allowance', [me, D.borrowerOperations]),
  ]);
  $('s-eth').textContent = fmt(eth, 4);
  $('s-wst').textContent = fmt(wst, 3);
  $('s-oct').textContent = fmt(oct, 2);
  Object.assign(bal, { eth, wst, oct, spDep: dep, coll: Number(status) === 1 ? coll : 0n, debt: Number(status) === 1 ? debt : 0n });
  $('sp-mine').textContent = fmt(dep, 2, 'OCT');
  $('sp-mine-share').textContent = total > 0n ? pct((dep * WAD) / total) : '—';
  $('sp-gain').textContent = fmt(gain, 4, 'wstETH');
  $('btn-approve').classList.toggle('hidden', allowance > 10n ** 30n);
  const names = ['none', 'open', 'closed by you', 'liquidated', 'redeemed', 'closed by succession'];
  $('v-status').textContent = names[Number(status)] || '—';
  hasVault = Number(status) === 1;
  $('v-coll').textContent = hasVault ? fmt(coll, 4, 'wstETH') : '—';
  $('v-debt').textContent = hasVault ? fmt(debt, 2, 'OCT') : '—';
  $('v-icr').textContent = hasVault ? pct(icrOf(coll, debt)) : '—';
  $('v-liq').textContent = hasVault ? `${usd(liqPrice(coll, debt))} per wstETH` : '—';
  if (hasVault) {
    // redemptions take the reserve first, then vaults from the lowest ratio up: everything below you is "in front"
    const mine = icrOf(coll, debt);
    const inFront = allTroves.filter((r) => r.owner.toLowerCase() !== me.toLowerCase() && icrOf(r.coll, r.debt) < mine).reduce((a, r) => a + r.debt, 0n);
    const cap = await read(D.redemptionBuffer, A.bufferAbi, 'redeemCapacity', [price]);
    $('v-front').textContent = `${fmt(cap + inFront, 0)} OCT · reserve ${fmt(cap, 0)}, riskier vaults ${fmt(inFront, 0)}`;
  } else { $('v-front').textContent = '—'; }
  $('btn-close').disabled = !hasVault;
  $('btn-claim-surplus').classList.toggle('hidden', surplus === 0n);
  $('form-auto').classList.toggle('hidden', !hasVault);
  if (hasVault) {
    const [cadence, lastSkim] = await read(D.borrowerOperations, A.borrowerOperationsAbi, 'autoRepay', [me]);
    const names = ['off', 'monthly', 'quarterly', 'yearly'];
    $('v-auto').textContent = cadence ? `${names[cadence]} · last run ${lastSkim ? date(lastSkim) : 'never'}` : 'off';
    if ($('auto-cadence').value !== String(cadence) && document.activeElement !== $('auto-cadence')) $('auto-cadence').value = String(cadence);
    const yieldWst = isZero(D.keeperDesk) ? 0n : await read(D.keeperDesk, A.keeperDeskAbi, 'skimmable', [me]);
    $('v-yield').textContent = yieldWst > 0n ? `${fmt(yieldWst, 6)} wstETH ≈ ${usd((yieldWst * price) / WAD)}` : 'none yet';
  } else { $('v-auto').textContent = '—'; $('v-yield').textContent = '—'; }
}

async function refreshSuccession() {
  if (!me) return;
  const [[state, dueAt, execAt], last, [accounts, bps], fallback, escrowW, escrowO] = await Promise.all([
    read(D.successionRegistry, A.registryAbi, 'successionState', [me]),
    read(D.successionRegistry, A.registryAbi, 'lastProof', [me]),
    read(D.successionRegistry, A.registryAbi, 'getHeirs', [me]),
    read(D.successionRegistry, A.registryAbi, 'getFallbackHeir', [me]),
    read(D.successionRegistry, A.registryAbi, 'escrowOf', [me, D.wstETH]),
    read(D.successionRegistry, A.registryAbi, 'escrowOf', [me, D.oct]),
  ]);
  hasPlan = state !== 0 && state !== 4;
  const states = ['no plan', 'active', 'due · owner-return window', 'executable by anyone', 'executed'];
  $('p-state').textContent = states[state] || '—';
  $('p-last').textContent = state === 0 ? '—' : date(last);
  $('p-due').textContent = state === 0 ? '—' : date(dueAt);
  $('p-exec').textContent = state === 0 ? '—' : date(execAt);
  $('p-heirs').innerHTML = accounts.length ? accounts.map((a, i) => `${short(a)} · ${(bps[i] / 100).toFixed(2)}%`).join('<br>') : '—';
  $('p-fallback').textContent = fallback === zeroAddress ? 'none' : short(fallback);
  $('btn-prove').disabled = state === 0;
  $('btn-clear-plan').disabled = state === 0;
  const esc = $('btn-escrow');
  esc.classList.toggle('hidden', escrowW === 0n && escrowO === 0n);
  esc.textContent = `Claim escrow (${fmt(escrowW, 4)} wstETH, ${fmt(escrowO, 2)} OCT)`;
  esc.onclick = async () => {
    if (escrowW > 0n) await send('Claim wstETH escrow', () => write(D.successionRegistry, A.registryAbi, 'claimEscrow', [D.wstETH]));
    if (escrowO > 0n) await send('Claim OCT escrow', () => write(D.successionRegistry, A.registryAbi, 'claimEscrow', [D.oct]));
  };
  if (accounts.length && heirRowCount === 0) { accounts.forEach((a, i) => addHeirRow(a, (bps[i] / 100).toString())); if (fallback !== zeroAddress) $('in-fallback').value = fallback; }
}

// the stepped flow: no vault -> steps 1-2; vault without a plan -> step 3 (the heir alert); both -> adjust + invitations
async function refreshFlow() {
  const connected = !!me;
  $('form-open').classList.toggle('hidden', connected && hasVault);
  $('form-adjust').classList.toggle('hidden', !(connected && hasVault));
  $('steps').classList.toggle('hidden', connected && hasVault && hasPlan);
  $('form-title').textContent = connected && hasVault ? 'Adjust your vault' : 'Open a vault';
  const stepNow = !(connected && hasVault) ? currentStep : 3;
  document.querySelectorAll('.step').forEach((el) => {
    const n = Number(el.dataset.step);
    el.classList.toggle('is-current', n === stepNow);
    el.classList.toggle('is-done', n < stepNow || (n === 3 && hasPlan));
  });
  const needsPlan = connected && hasVault && !hasPlan;
  $('plan-alert').classList.toggle('hidden', !needsPlan);
  $('btn-skip-plan').classList.toggle('hidden', !needsPlan);
  $('invite').classList.toggle('hidden', !(connected && hasVault && (hasPlan || planSkipped)));
}
let currentStep = 1; let planSkipped = false;
function showStep(n) {
  currentStep = n;
  $('pane-1').classList.toggle('hidden', n !== 1);
  $('pane-2').classList.toggle('hidden', n !== 2);
  document.querySelectorAll('.step').forEach((el) => { const k = Number(el.dataset.step); el.classList.toggle('is-current', k === n); el.classList.toggle('is-done', k < n); });
}

// ---------- Keeper desk ----------
async function refreshDesk() {
  if (isZero(D.keeperDesk)) { $('k-liq').textContent = 'desk not deployed'; return; }
  try {
    desk = await read(D.keeperDesk, A.keeperDeskAbi, 'pending', [60n]);
    $('k-liq').textContent = desk.liquidatable.length ? `${desk.liquidatable.length} (${desk.liquidatable.map(short).join(', ')})` : 'none';
    $('k-exe').textContent = desk.executable.length ? `${desk.executable.length} (${desk.executable.map(short).join(', ')})` : 'none';
    $('k-skim').textContent = desk.skimmable.length ? `${desk.skimmable.length} (${desk.skimmable.map(short).join(', ')})` : 'none due';
    $('k-tend').textContent = desk.tend ? 'a release, a split or a pool deposit is due' : 'nothing due';
    const any = desk.octReward > 0n || desk.collReward > 0n;
    $('k-reward').textContent = any ? `≈ ${fmt(desk.octReward, 0)} OCT + ${fmt(desk.collReward, 4)} wstETH` : 'none pending';
    $('k-reward').style.color = any ? 'var(--gold-2)' : '';
    $('btn-desk-liq').disabled = desk.liquidatable.length === 0;
    $('btn-desk-tend').disabled = !desk.tend;
  } catch (e) { console.error(e); $('k-liq').textContent = '—'; }
}
// Three jobs, three buttons: each transaction carries only its own calls (LS_06 #169)
async function runDesk(category) {
  if (isZero(D.keeperDesk)) { toast('The desk is not deployed on this chain.', 'bad'); return; }
  let liq = [], exe = [], skim = [], tend = false, label = '';
  if (category === 'liq') { liq = desk ? [...desk.liquidatable] : []; label = 'Liquidate'; if (!liq.length) { toast('Nothing to liquidate.', 'warn'); return; } }
  if (category === 'estates') {
    const extra = $('ex-addr').value.trim();
    if (extra && !looksLikeAddress(extra)) { toast('That is not an address.', 'bad'); return; }
    exe = desk ? [...desk.executable] : []; skim = desk ? [...desk.skimmable] : [];
    if (extra && !exe.map((a) => a.toLowerCase()).includes(extra.toLowerCase())) exe.push(addr(extra));
    label = 'Settle and auto-repay'; if (!exe.length && !skim.length) { toast('No estate is due and no auto-repay is due.', 'warn'); return; }
  }
  if (category === 'tend') { tend = true; label = 'Reserve housekeeping'; }
  await send(label, () => writePadded(D.keeperDesk, A.keeperDeskAbi, 'run', [liq, exe, skim, tend]));
}
async function executePreview() {
  const a = $('ex-addr').value.trim(); const p = $('ex-preview'); p.className = 'preview';
  if (!looksLikeAddress(a)) { p.textContent = 'Enter a wallet to read its state.'; return; }
  const [state, dueAt, execAt] = await read(D.successionRegistry, A.registryAbi, 'successionState', [addr(a)]);
  const states = ['no plan', 'active', 'due · owner-return window', 'executable by anyone', 'executed'];
  p.textContent = `${states[state]}${state ? ` · due ${date(dueAt)} · executable ${date(execAt)}` : ''}`;
  if (state === 3) p.className = 'preview warn';
}

// ---------- market ----------
async function refreshMarket() {
  const sec = $('market');
  if (isZero(D.octUsdePool)) { sec.classList.add('hidden'); return; }
  sec.classList.remove('hidden');
  try {
    const [[sqrtP], t0, octBal, usdeBal] = await Promise.all([
      read(D.octUsdePool, A.uniswapPoolAbi, 'slot0'),
      read(D.octUsdePool, A.uniswapPoolAbi, 'token0'),
      read(D.oct, A.erc20Abi, 'balanceOf', [D.octUsdePool]),
      read(D.usde, A.erc20Abi, 'balanceOf', [D.octUsdePool]),
    ]);
    // price of token1 in token0 = (sqrtP / 2^96)^2; OCT price in USDe depends on which side OCT is
    const p1in0 = (sqrtP * sqrtP * WAD) / (Q96 * Q96);
    const octIs0 = t0.toLowerCase() === D.oct.toLowerCase();
    const octPrice = octIs0 ? p1in0 === 0n ? 0n : (WAD * WAD) / p1in0 : p1in0;
    $('m-price').textContent = `${Number(formatUnits(octPrice, 18)).toFixed(4)} USDe`;
    const diff = Number(formatUnits(octPrice, 18)) - 1;
    $('m-par').textContent = `${diff >= 0 ? '+' : ''}${(diff * 100).toFixed(2)}%`;
    $('m-par').style.color = Math.abs(diff) < 0.005 ? 'var(--ok)' : Math.abs(diff) < 0.02 ? 'var(--warn)' : 'var(--bad)';
    $('m-liq').textContent = `${fmt(octBal, 0)} OCT + ${fmt(usdeBal, 0)} USDe`;
    const base = NET.uniswap ? `https://app.uniswap.org` : '';
    $('lnk-swap').href = base ? `${base}/swap?chain=${NET.uniswap}&inputCurrency=${D.usde}&outputCurrency=${D.oct}` : '#';
    $('lnk-lp').href = base ? `${base}/positions/create/v3?currencyA=${D.oct}&currencyB=${D.usde}&chain=${NET.uniswap}` : '#';
    $('lnk-pool').href = NET.explorer ? `${NET.explorer}/address/${D.octUsdePool}` : '#';
  } catch (e) { console.error(e); $('m-price').textContent = '—'; }
}

// ---------- vault forms ----------
function collPreview() {
  const coll = toWad($('in-coll').value); const p = $('coll-preview'); p.className = 'preview';
  if (coll === 0n) { p.textContent = 'Enter an amount to see what it can back.'; return; }
  const value = (coll * price) / WAD;
  const max = (value * WAD) / MCR;            // at exactly 110%, not advisable
  const safe = (value * WAD) / (2n * WAD);    // at 200%
  p.textContent = `Worth ${usd(value)} today. It can back at most ${fmt(max, 0)} OCT at the 110% floor; a comfortable line is around ${fmt(safe, 0)} OCT (200%).`;
}
function openPreview() {
  const coll = toWad($('in-coll').value); const debt = toWad($('in-debt').value);
  const p = $('open-preview'); p.className = 'preview';
  if (coll === 0n || debt === 0n) { p.textContent = 'Enter amounts to see the ratio, the fee and the liquidation price.'; return; }
  const fee = debt / 200n; const composite = debt + fee + GAS_COMP;
  const icr = icrOf(coll, composite);
  const share = (x) => `${(Number(x * 10000n / composite) / 100).toFixed(1)}%`;
  const lines = [`You receive ${fmt(debt, 2)} OCT (${share(debt)} of the total debt of ${fmt(composite, 2)} OCT). The reserve keeps the 0.5% mint fee, ${fmt(fee, 2)} OCT (${share(fee)}). 200 OCT (${share(GAS_COMP)}) is parked as liquidation reserve and returned when you close.`,
    `Collateral ratio: ${pct(icr)}. Liquidation if wstETH falls under ${usd(liqPrice(coll, composite))} (now ${usd(price)}).`];
  if (debt < MIN_NET_DEBT) { lines.push('Minimum debt is 1,800 OCT.'); p.className = 'preview bad'; }
  else if (icr < 15n * 10n ** 17n) { lines.push('Under 150%: allowed, but a 27% drop liquidates you. Consider a larger margin.'); p.className = 'preview warn'; }
  p.textContent = lines.join('\n');
}
function adjustPreview() {
  const p = $('adjust-preview'); p.className = 'preview';
  const add = toWad($('adj-add-coll').value), wd = toWad($('adj-wd-coll').value), bor = toWad($('adj-borrow').value), rep = toWad($('adj-repay').value);
  if (add > 0n && wd > 0n) { p.textContent = 'Choose either add or withdraw collateral, not both.'; p.className = 'preview bad'; return; }
  if (bor > 0n && rep > 0n) { p.textContent = 'Choose either borrow or repay, not both.'; p.className = 'preview bad'; return; }
  p.textContent = 'One collateral change and one debt change per transaction. Borrowing pays the 0.5% mint fee on the new amount.';
}
async function zap() {
  const amount = toWad($('zap-amount').value);
  if (amount === 0n) { toast('Enter the ETH amount to convert.', 'bad'); return; }
  await send('Convert ETH to wstETH', () => wallet.sendTransaction({ account: me, to: D.wstETH, value: amount, chain: NET.chain }));
}
async function openVault(ev) {
  ev.preventDefault();
  const coll = toWad($('in-coll').value); const debt = toWad($('in-debt').value);
  if (coll === 0n || debt === 0n) { toast('Enter both amounts.', 'bad'); return; }
  const allowance = await read(D.wstETH, A.erc20Abi, 'allowance', [me, D.borrowerOperations]);
  if (allowance < coll) { const rc = await send('Approve wstETH', () => write(D.wstETH, A.erc20Abi, 'approve', [D.borrowerOperations, 2n ** 256n - 1n])); if (!rc) return; }
  const composite = debt + debt / 200n + GAS_COMP;
  const [upper, lower] = await insertHints(nominalCR(coll, composite));
  const rc = await send('Open vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'openTrove', [MAX_FEE, debt, upper, lower, coll]));
  if (!rc) return;
  const cadence = Number($('open-cadence').value);
  if (cadence) await send('Auto-repay from staking rewards', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'setAutoRepay', [cadence]));
  showStep(3); document.getElementById('succession').scrollIntoView({ behavior: 'smooth' });
}
async function saveAutoRepay(ev) {
  ev.preventDefault();
  await send('Save the auto-repay schedule', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'setAutoRepay', [Number($('auto-cadence').value)]));
}
async function skimNow() {
  if (!hasVault) return;
  await send('Skim the staking yield', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'skimYield', [me, zeroAddress, zeroAddress]));
}
async function adjustVault(ev) {
  ev.preventDefault();
  const add = toWad($('adj-add-coll').value), wd = toWad($('adj-wd-coll').value), bor = toWad($('adj-borrow').value), rep = toWad($('adj-repay').value);
  if ((add > 0n && wd > 0n) || (bor > 0n && rep > 0n)) { toast('One collateral change and one debt change at a time.', 'bad'); return; }
  if (add === 0n && wd === 0n && bor === 0n && rep === 0n) { toast('Nothing to change.', 'bad'); return; }
  const [debt, coll] = await read(D.troveManager, A.troveManagerAbi, 'getEntireDebtAndColl', [me]);
  const isInc = bor > 0n; const change = isInc ? bor : rep;
  const newColl = coll + add - wd; const newDebt = isInc ? debt + bor + bor / 200n : debt - rep;
  const [upper, lower] = await insertHints(nominalCR(newColl, newDebt));
  await send('Adjust vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'adjustTrove', [MAX_FEE, wd, change, isInc, upper, lower, add]));
}

// ---------- succession forms ----------
function addHeirRow(addr = '', share = '') {
  heirRowCount++;
  const row = document.createElement('div'); row.className = 'heir-row';
  row.innerHTML = `<label>Heir address<input type="text" class="heir-addr" placeholder="0x…" value="${addr}"></label><label>Share %<input type="number" class="heir-bps" step="0.01" min="0" max="100" value="${share}"></label><button type="button" class="x" title="remove">×</button>`;
  row.querySelector('.x').addEventListener('click', () => { row.remove(); planPreview(); });
  row.querySelectorAll('input').forEach((i) => i.addEventListener('input', planPreview));
  $('heir-rows').appendChild(row);
  planPreview();
}
function readPlan() {
  const rows = [...document.querySelectorAll('.heir-row')];
  const accounts = rows.map((r) => r.querySelector('.heir-addr').value.trim());
  const bps = rows.map((r) => Math.round(parseFloat(r.querySelector('.heir-bps').value || '0') * 100));
  return { accounts, bps };
}
function planPreview() {
  const { accounts, bps } = readPlan();
  const total = bps.reduce((a, b) => a + b, 0);
  const p = $('plan-preview'); p.className = 'preview';
  const bar = $('meter-bar');
  bar.style.width = `${Math.min(100, total / 100)}%`;
  bar.className = `meter-bar${total === 10000 ? ' full' : total > 10000 ? ' over' : ''}`;
  const bad = accounts.filter((a) => a && !looksLikeAddress(a));
  if (bad.length) { p.textContent = `Not an address: ${bad[0]}`; p.className = 'preview bad'; return; }
  if (accounts.length === 0) { p.textContent = 'Add at least one heir.'; return; }
  p.textContent = total === 10000 ? `${accounts.length} heir${accounts.length > 1 ? 's' : ''}, shares total 100%. Ready to save.` : `Shares total ${(total / 100).toFixed(2)}%; they must total exactly 100%.`;
  if (total !== 10000) p.className = 'preview warn';
}
async function savePlan(ev) {
  ev.preventDefault();
  const { accounts, bps } = readPlan();
  if (accounts.some((a) => !looksLikeAddress(a)) || bps.reduce((a, b) => a + b, 0) !== 10000) { toast('Check the heirs and the shares.', 'bad'); return; }
  const fb = $('in-fallback').value.trim();
  if (fb && !looksLikeAddress(fb)) { toast('The fallback heir is not an address.', 'bad'); return; }
  await send('Save plan', () => write(D.successionRegistry, A.registryAbi, 'setPlan', [accounts.map(addr), bps, fb ? addr(fb) : zeroAddress]));
}
async function giftCollateral(ev) {
  ev.preventDefault();
  const owner = $('gift-owner').value.trim();
  const amount = toWad($('gift-amount').value);
  if (!looksLikeAddress(owner)) { toast('Enter the vault owner\'s address.', 'bad'); return; }
  if (amount <= 0n) { toast('Enter the wstETH amount.', 'bad'); return; }
  if (!(await ensureAllowance(D.borrowerOperations, amount, 'the vault'))) return;
  await send('Add collateral to the vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'addCollateralFor', [addr(owner), zeroAddress, zeroAddress, amount]));
}

// ---------- buffer forms ----------
async function ensureAllowance(spender, amount, label) {
  const allowance = await read(D.wstETH, A.erc20Abi, 'allowance', [me, spender]);
  if (allowance >= amount) return true;
  const rc = await send(`Approve wstETH for ${label}`, () => write(D.wstETH, A.erc20Abi, 'approve', [spender, 2n ** 256n - 1n]));
  return !!rc;
}
async function redeem(ev) {
  ev.preventDefault();
  const amount = toWad($('rd-amount').value);
  if (amount < 5000n * WAD) { toast('Minimum redemption is 5,000 OCT.', 'bad'); return; }
  const [first, partialNICR, truncated] = await read(D.hintHelpers, A.hintHelpersAbi, 'getRedemptionHints', [amount, price, 0n]);
  if (truncated === 0n) { toast('Nothing can be redeemed right now.', 'bad'); return; }
  let upper = zeroAddress, lower = zeroAddress;
  if (partialNICR > 0n) { [upper, lower] = await insertHints(partialNICR); }
  const maxFee = WAD; // accept the current rate on the testnet; a production frontend passes the quoted rate plus a tolerance
  await send('Redeem', () => write(D.troveManager, A.troveManagerAbi, 'redeemCollateral', [truncated, first, upper, lower, partialNICR, 0n, maxFee]));
}
async function buyPreview() {
  const amount = toWad($('buy-amount').value); const p = $('buy-preview');
  if (amount === 0n) { p.textContent = ''; return; }
  const quote = await read(D.redemptionBuffer, A.bufferAbi, 'quoteInventory', [amount, price]);
  p.textContent = `Costs ${fmt(quote, 5)} wstETH (oracle price plus 0.5%).`;
}
async function buyInventory(ev) {
  ev.preventDefault();
  const amount = toWad($('buy-amount').value);
  if (amount === 0n) return;
  const quote = await read(D.redemptionBuffer, A.bufferAbi, 'quoteInventory', [amount, price]);
  const maxIn = (quote * 101n) / 100n;
  if (!(await ensureAllowance(D.redemptionBuffer, maxIn, 'the reserve'))) return;
  await send('Take the offer', () => write(D.redemptionBuffer, A.bufferAbi, 'buyInventory', [amount, maxIn]));
}
async function fillPot(ev) {
  ev.preventDefault();
  const amount = toWad($('fill-amount').value);
  if (amount === 0n) return;
  if (!(await ensureAllowance(D.redemptionBuffer, amount, 'the reserve'))) return;
  await send('Add to the reserve', () => write(D.redemptionBuffer, A.bufferAbi, 'fill', [amount]));
}
async function depositReserve(ev) {
  ev.preventDefault();
  const amount = toWad($('dep-amount').value);
  if (amount === 0n) { toast('Enter the wstETH amount.', 'bad'); return; }
  if (!(await ensureAllowance(D.redemptionBuffer, amount, 'the reserve'))) return;
  await send('Reserve deposit', () => write(D.redemptionBuffer, A.bufferAbi, 'deposit', [amount]));
}
async function withdrawReserve() {
  const amount = toWad($('dep-amount').value) || bal.rdDep;     // empty field: the whole deposit
  if (amount === 0n) { toast('Nothing deposited.', 'bad'); return; }
  await send('Withdraw the deposit', () => write(D.redemptionBuffer, A.bufferAbi, 'withdraw', [amount]));
}
async function buyLot() {
  const cost = await read(D.burnAuction, A.auctionAbi, 'cost');
  const bal = await read(D.stack, A.erc20Abi, 'balanceOf', [me]);
  if (bal < cost) { toast(`The lot costs ${fmt(cost, 2)} STACK; you hold ${fmt(bal, 2)}.`, 'bad'); return; }
  const allowance = await read(D.stack, A.erc20Abi, 'allowance', [me, D.burnAuction]);
  if (allowance < cost) { const rc = await send('Approve STACK', () => write(D.stack, A.erc20Abi, 'approve', [D.burnAuction, 2n ** 256n - 1n])); if (!rc) return; }
  await send('Buy the lot', () => write(D.burnAuction, A.auctionAbi, 'buy', [(cost * 102n) / 100n]));
}

// ---------- Max buttons: fill a field with what the wallet or the position allows ----------
const SAFE = 15n * 10n ** 17n;                 // the computed maxima keep the vault at 150%, never at the 110% line
const MAX_RULES = {
  'zap-amount':   () => ({ v: bal.eth > 5n * 10n ** 15n ? bal.eth - 5n * 10n ** 15n : 0n, d: 18, why: 'your ETH, less a little for gas' }),
  'in-coll':      () => ({ v: bal.wst, d: 18, why: 'your wstETH' }),
  'adj-add-coll': () => ({ v: bal.wst, d: 18, why: 'your wstETH' }),
  'gift-amount':  () => ({ v: bal.wst, d: 18, why: 'your wstETH' }),
  'fill-amount':  () => ({ v: bal.wst, d: 18, why: 'your wstETH' }),
  'dep-amount':   () => ({ v: bal.wst, d: 18, why: 'your wstETH' }),
  'in-debt':      () => { const coll = toWad($('in-coll').value); if (coll === 0n) return { v: null, why: 'enter the collateral first' };
                          const composite = (coll * price) / SAFE; const v = composite > GAS_COMP ? ((composite - GAS_COMP) * 1000n) / 1005n : 0n; return { v, d: 0, why: 'what keeps the vault at 150%' }; },
  'adj-borrow':   () => { const room = (bal.coll * price) / SAFE; const v = room > bal.debt ? ((room - bal.debt) * 1000n) / 1005n : 0n; return { v, d: 0, why: 'what keeps the vault at 150%' }; },
  'adj-wd-coll':  () => { const need = price > 0n ? (bal.debt * SAFE) / price : bal.coll; return { v: bal.coll > need ? bal.coll - need : 0n, d: 4, why: 'what keeps the vault at 150%' }; },
  'adj-repay':    () => { const toMin = bal.debt > GAS_COMP + MIN_NET_DEBT ? bal.debt - GAS_COMP - MIN_NET_DEBT : 0n; return { v: toMin < bal.oct ? toMin : bal.oct, d: 18, why: 'down to the 1,800 OCT minimum; use Close vault to repay everything' }; },
  'rd-amount':    () => ({ v: bal.oct, d: 18, why: 'your OCT' }),
  'sp-amount':    () => ({ v: bal.oct, d: 18, why: 'your OCT; an empty field withdraws the whole deposit' }),
  'buy-amount':   () => { const afford = (((bal.wst * price) / WAD) * 1000n) / 1005n; return { v: afford < bal.inv ? afford : bal.inv, d: 2, why: 'what your wstETH buys, up to the inventory' }; },
};
function wireMax() {
  for (const [id, rule] of Object.entries(MAX_RULES)) {
    const input = $(id); if (!input) continue;
    const label = input.closest('label'); label.classList.add('has-max');
    const b = document.createElement('button'); b.type = 'button'; b.className = 'max'; b.textContent = 'Max'; b.title = rule().why;
    b.addEventListener('click', () => {
      if (!me) { toast('Connect a wallet first.', 'warn'); return; }
      const { v, d, why } = rule();
      if (v === null) { toast(why, 'warn'); return; }
      if (v === 0n) { toast(`Nothing available: ${why}.`, 'warn'); return; }
      const str = formatUnits(v, 18); input.value = d >= 18 ? str : trimTo(str, d);
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    label.appendChild(b);
  }
}
const trimTo = (str, d) => { const [i, f = ''] = str.split('.'); const frac = f.slice(0, d).replace(/0+$/, ''); return frac ? `${i}.${frac}` : i; };

// ---------- show a token in the wallet (EIP-747) ----------
const TOKENS = { oct: () => D.oct, wst: () => D.wstETH, usde: () => D.usde, stack: () => D.stack };
async function watchAsset(key) {
  const address = TOKENS[key]?.();
  if (!window.ethereum) { toast('No wallet found.', 'bad'); return; }
  if (isZero(address)) { toast('That token is not deployed on this chain.', 'bad'); return; }
  try {
    const symbol = await read(address, A.erc20Abi, 'symbol');
    const added = await window.ethereum.request({ method: 'wallet_watchAsset', params: { type: 'ERC20', options: { address, symbol, decimals: 18 } } });
    toast(added ? `${symbol} is now listed in your wallet.` : `Your wallet declined to list ${symbol}.`, added ? 'ok' : 'warn');
  } catch (e) { toast(explain(e), 'bad'); }
}

// ---------- boot ----------
async function boot() {
  const res = await fetch(DEPLOYMENT_URL, { cache: 'no-store' });
  D = await res.json();
  NET = CHAINS[D.chainId];
  if (!NET) {
    // no public test deployment yet: the strategy reads, the vault waits
    $('net-badge').textContent = 'test deployment pending';
    $('btn-connect').disabled = true;
    document.querySelectorAll('.panel').forEach((p) => { p.querySelectorAll('button, input').forEach((el) => { el.disabled = true; }); });
    toast('The contracts are not yet deployed on the public test network. The strategy and mechanics read as usual; the vault opens once the deployment lands.', 'warn');
    return;
  }
  pub = createPublicClient({ chain: NET.chain, transport: http(NET.rpc), pollingInterval: 2000 });

  const list = $('addr-list');
  for (const [k, v] of Object.entries(D)) {
    if (typeof v !== 'string' || !v.startsWith('0x') || isZero(v)) continue;
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.innerHTML = NET.explorer ? `<a href="${NET.explorer}/address/${v}" target="_blank" rel="noopener">${v}</a>` : v;
    list.append(dt, dd);
  }

  $('btn-connect').addEventListener('click', connect);
  wireMax();
  document.querySelectorAll('[data-watch]').forEach((b) => b.addEventListener('click', () => watchAsset(b.dataset.watch)));
  $('form-open').addEventListener('submit', openVault);
  $('form-adjust').addEventListener('submit', adjustVault);
  $('in-coll').addEventListener('input', () => { collPreview(); openPreview(); });
  $('in-debt').addEventListener('input', openPreview);
  ['adj-add-coll', 'adj-wd-coll', 'adj-borrow', 'adj-repay'].forEach((id) => $(id).addEventListener('input', adjustPreview));
  document.querySelectorAll('[data-next]').forEach((b) => b.addEventListener('click', () => {
    const n = Number(b.dataset.next);
    if (n === 2 && toWad($('in-coll').value) === 0n) { toast('Enter the collateral first.', 'bad'); return; }
    showStep(n);
  }));
  $('btn-zap').addEventListener('click', zap);
  $('btn-close').addEventListener('click', () => send('Close vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'closeTrove')));
  $('btn-claim-surplus').addEventListener('click', () => send('Claim collateral', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'claimCollateral')));
  $('btn-faucet').addEventListener('click', () => send('Mint test wstETH', () => write(D.wstETH, A.wstAbi, 'mint', [me, 10n * WAD])));
  $('btn-faucet-usde').addEventListener('click', () => { if (isZero(D.usde)) { toast('No test USDe on this chain.', 'bad'); return; } send('Mint test USDe', () => write(D.usde, A.wstAbi, 'mint', [me, 10000n * WAD])); });
  $('btn-approve').addEventListener('click', () => send('Approve wstETH', () => write(D.wstETH, A.erc20Abi, 'approve', [D.borrowerOperations, 2n ** 256n - 1n])));
  $('btn-add-heir').addEventListener('click', () => addHeirRow());
  $('form-plan').addEventListener('submit', savePlan);
  $('btn-skip-plan').addEventListener('click', () => { planSkipped = true; refreshFlow(); toast('Plan skipped. The alert stays until heirs are named.', 'warn'); });
  $('btn-prove').addEventListener('click', () => send('Proof of life', () => write(D.successionRegistry, A.registryAbi, 'proveLife')));
  $('btn-clear-plan').addEventListener('click', () => send('Remove plan', () => write(D.successionRegistry, A.registryAbi, 'clearPlan')));
  $('form-gift').addEventListener('submit', giftCollateral);
  $('form-auto').addEventListener('submit', saveAutoRepay);
  $('btn-skim').addEventListener('click', skimNow);
  $('form-execute').addEventListener('submit', (ev) => { ev.preventDefault(); runDesk('estates'); });
  $('btn-desk-liq').addEventListener('click', () => runDesk('liq'));
  $('btn-desk-tend').addEventListener('click', () => runDesk('tend'));
  $('ex-addr').addEventListener('input', () => executePreview().catch(() => {}));
  $('form-redeem').addEventListener('submit', redeem);
  $('form-buy').addEventListener('submit', buyInventory);
  $('buy-amount').addEventListener('input', () => buyPreview().catch(() => {}));
  $('form-fill').addEventListener('submit', fillPot);
  $('form-deposit').addEventListener('submit', depositReserve);
  $('btn-withdraw').addEventListener('click', withdrawReserve);
  $('btn-claim-stack').addEventListener('click', () => send('Claim STACK', () => write(D.reserveRewards, A.rewardsAbi, 'claim')));
  $('btn-buy-lot').addEventListener('click', buyLot);
  $('btn-faucet-stack').addEventListener('click', () => { if (isZero(D.stack)) { toast('No test STACK on this chain.', 'bad'); return; } send('Mint test STACK', () => write(D.stack, A.wstAbi, 'mint', [me, 1000n * WAD])); });
  $('btn-sp-deposit').addEventListener('click', () => { const a = toWad($('sp-amount').value); if (a > 0n) send('Deposit to the pool', () => write(D.stabilityPool, A.stabilityPoolAbi, 'provideToSP', [a])); });
  $('btn-sp-withdraw').addEventListener('click', () => { const a = toWad($('sp-amount').value) || bal.spDep; if (a === 0n) { toast('Nothing deposited.', 'bad'); return; } send('Withdraw from the pool', () => write(D.stabilityPool, A.stabilityPoolAbi, 'withdrawFromSP', [a])); });
  $('btn-sp-claim').addEventListener('click', () => send('Claim pool gain', () => write(D.stabilityPool, A.stabilityPoolAbi, 'withdrawFromSP', [0n])));

  if ($('heir-rows').children.length === 0) addHeirRow();
  showStep(1);
  await refresh();
  refreshTimer = setInterval(() => refresh().catch(() => {}), 15000);
  if (window.ethereum && (await window.ethereum.request({ method: 'eth_accounts' })).length) connect();
}
boot().catch((e) => { console.error(e); toast(`Could not start: ${e.message}`, 'bad'); });
