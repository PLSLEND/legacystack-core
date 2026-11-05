import { createPublicClient, createWalletClient, custom, http, formatUnits, parseUnits, getAddress, isAddress, zeroAddress, defineChain, BaseError, ContractFunctionRevertedError } from 'viem';
import { sepolia } from 'viem/chains';
import * as A from './abis.js';

// ---------- configuration ----------
const DEPLOYMENT_URL = 'deployment.json';
const CHAINS = {
  11155111: { chain: sepolia, rpc: 'https://ethereum-sepolia-rpc.publicnode.com', explorer: 'https://sepolia.etherscan.io', name: 'Sepolia' },
  31337: { chain: defineChain({ id: 31337, name: 'Local', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } } }), rpc: 'http://127.0.0.1:8545', explorer: '', name: 'local chain' },
};
const WAD = 10n ** 18n;
const MCR = 11n * 10n ** 17n;
const GAS_COMP = 200n * WAD;
const MIN_NET_DEBT = 1800n * WAD;
const MAX_FEE = 5n * 10n ** 16n; // the protocol's own cap on the mint fee (5%)

let D = null;           // deployment addresses
let NET = null;         // chain config
let pub = null;         // public client
let wallet = null;      // wallet client
let me = null;          // connected address
let price = 0n; let healthy = true;
let refreshTimer = null;
let heirRowCount = 0;

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
  return reason.replace(/^(BorrowerOps|TroveManager|TM|StabilityPool|RedemptionBuffer|SuccessionRegistry|LUSD|PriceFeed): /, '');
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
    $('s-price').textContent = `$${fmt(price, 0)}`;
    const reduceOnly = await read(D.priceFeed, A.priceFeedAbi, 'isReduceOnly');
    $('s-oracle').textContent = healthy && !reduceOnly ? 'healthy' : 'degraded · reduce-only';
    $('s-oracle').style.color = healthy && !reduceOnly ? 'var(--ok)' : 'var(--warn)';
    await Promise.all([refreshSystem(), refreshBuffer(), refreshPoolAndVault(), refreshSuccession(), networkBadge()]);
  } catch (e) { console.error(e); toast(`Could not read the chain: ${explain(e)}`, 'bad'); }
}

async function refreshSystem() {
  const [coll, debt, count, mintFee, redFee] = await Promise.all([
    read(D.troveManager, A.troveManagerAbi, 'getEntireSystemColl'),
    read(D.troveManager, A.troveManagerAbi, 'getEntireSystemDebt'),
    read(D.troveManager, A.troveManagerAbi, 'getTroveOwnersCount'),
    read(D.troveManager, A.troveManagerAbi, 'getBorrowingRateWithDecay'),
    read(D.troveManager, A.troveManagerAbi, 'getRedemptionRateWithDecay'),
  ]);
  $('y-coll').textContent = fmt(coll, 2, 'wstETH');
  $('y-debt').textContent = fmt(debt, 0, 'OCT');
  $('y-tcr').textContent = pct(icrOf(coll, debt));
  $('y-count').textContent = count.toString();
  $('y-mintfee').textContent = pct(mintFee);
  $('y-redfee').textContent = pct(redFee);
  // riskiest vaults
  const rows = await read(D.multiTroveGetter, A.multiTroveGetterAbi, 'getMultipleSortedTroves', [-1n, 12n]);
  const tb = $('trove-table').querySelector('tbody'); tb.innerHTML = '';
  for (const r of rows) {
    const icr = icrOf(r.coll, r.debt);
    const risky = icr < MCR;
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${short(r.owner)}</td><td>${fmt(r.coll, 3)}</td><td>${fmt(r.debt, 0)}</td><td class="${risky ? 'risk' : ''}">${pct(icr)}</td><td>${risky ? `<button class="btn btn-small" data-liq="${r.owner}">Liquidate</button>` : ''}</td>`;
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
  $('b-pot').textContent = `${fmt(pot, 3)} wstETH ($${fmt(potUsd, 0)})`;
  $('b-target').textContent = `$${fmt(target, 0)} (15% of ${fmt(circ, 0)} OCT)`;
  $('b-inv').textContent = `${fmt(inv, 2)} OCT`;
  $('b-ceiling').textContent = `$${fmt(ceiling, 0)} · used ${fmt(debt, 0)}`;
  $('rd-preview').textContent = `The reserve can serve ${fmt(cap, 0)} OCT right now; anything above that is redeemed from the riskiest vaults.`;
}

async function refreshPoolAndVault() {
  const total = await read(D.stabilityPool, A.stabilityPoolAbi, 'getTotalLUSDDeposits');
  $('sp-total').textContent = fmt(total, 0, 'OCT');
  if (!me) return;
  const [wst, oct, status, [debt, coll], dep, gain, surplus, allowance] = await Promise.all([
    read(D.wstETH, A.erc20Abi, 'balanceOf', [me]), read(D.oct, A.erc20Abi, 'balanceOf', [me]),
    read(D.troveManager, A.troveManagerAbi, 'getTroveStatus', [me]),
    read(D.troveManager, A.troveManagerAbi, 'getEntireDebtAndColl', [me]),
    read(D.stabilityPool, A.stabilityPoolAbi, 'getCompoundedLUSDDeposit', [me]),
    read(D.stabilityPool, A.stabilityPoolAbi, 'getDepositorETHGain', [me]),
    read(D.collSurplusPool, A.collSurplusPoolAbi, 'getCollateral', [me]),
    read(D.wstETH, A.erc20Abi, 'allowance', [me, D.borrowerOperations]),
  ]);
  $('s-wst').textContent = fmt(wst, 3);
  $('s-oct').textContent = fmt(oct, 2);
  $('sp-mine').textContent = fmt(dep, 2, 'OCT');
  $('sp-gain').textContent = fmt(gain, 4, 'wstETH');
  $('btn-approve').classList.toggle('hidden', allowance > 10n ** 30n);
  const names = ['none', 'open', 'closed by you', 'liquidated', 'redeemed', 'closed by succession'];
  $('v-status').textContent = names[Number(status)] || '—';
  const active = Number(status) === 1;
  $('v-coll').textContent = active ? fmt(coll, 4, 'wstETH') : '—';
  $('v-debt').textContent = active ? fmt(debt, 2, 'OCT') : '—';
  $('v-icr').textContent = active ? pct(icrOf(coll, debt)) : '—';
  $('v-liq').textContent = active ? `$${fmt(liqPrice(coll, debt), 0)} per wstETH` : '—';
  $('btn-close').disabled = !active;
  $('btn-claim-surplus').classList.toggle('hidden', surplus === 0n);
  $('form-open').classList.toggle('hidden', active);
  $('form-adjust').classList.toggle('hidden', !active);
  $('form-title').textContent = active ? 'Adjust your vault' : 'Open a vault';
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

// ---------- vault forms ----------
function openPreview() {
  const coll = toWad($('in-coll').value); const debt = toWad($('in-debt').value);
  const p = $('open-preview'); p.className = 'preview';
  if (coll === 0n || debt === 0n) { p.textContent = 'Enter amounts to see the ratio, the fee and the liquidation price.'; return; }
  const fee = debt / 200n; const composite = debt + fee + GAS_COMP;
  const icr = icrOf(coll, composite);
  const lines = [`Mint fee 0.5%: ${fmt(fee, 2)} OCT. Total debt: ${fmt(composite, 2)} OCT (includes 200 OCT held as liquidation reserve, returned when you close).`,
    `Collateral ratio: ${pct(icr)}. Liquidation if wstETH falls under $${fmt(liqPrice(coll, composite), 0)} (now $${fmt(price, 0)}).`];
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
async function openVault(ev) {
  ev.preventDefault();
  const coll = toWad($('in-coll').value); const debt = toWad($('in-debt').value);
  if (coll === 0n || debt === 0n) { toast('Enter both amounts.', 'bad'); return; }
  const composite = debt + debt / 200n + GAS_COMP;
  const [upper, lower] = await insertHints(nominalCR(coll, composite));
  await send('Open vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'openTrove', [MAX_FEE, debt, upper, lower, coll]));
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
  const bad = accounts.filter((a) => a && !looksLikeAddress(a));
  if (bad.length) { p.textContent = `Not an address: ${bad[0]}`; p.className = 'preview bad'; return; }
  if (accounts.length === 0) { p.textContent = 'Add at least one heir.'; return; }
  p.textContent = total === 10000 ? `${accounts.length} heir${accounts.length > 1 ? 's' : ''}, shares total 100%.` : `Shares total ${(total / 100).toFixed(2)}%; they must total 100%.`;
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
async function saveOperator(ev) {
  ev.preventDefault();
  const op = $('op-addr').value.trim();
  if (!looksLikeAddress(op)) { toast('Enter the operator address.', 'bad'); return; }
  const floor = parseUnits(String($('op-floor').value || '250'), 16);
  await send('Save operator', () => write(D.successionRegistry, A.registryAbi, 'setOperator', [addr(op), $('op-active').checked, $('op-borrow').checked, floor]));
}
async function executePreview() {
  const a = $('ex-addr').value.trim(); const p = $('ex-preview'); p.className = 'preview';
  if (!looksLikeAddress(a)) { p.textContent = 'Enter a wallet to read its state.'; return; }
  const [state, dueAt, execAt] = await read(D.successionRegistry, A.registryAbi, 'successionState', [addr(a)]);
  const states = ['no plan', 'active', 'due · owner-return window', 'executable by anyone', 'executed'];
  p.textContent = `${states[state]}${state ? ` · due ${date(dueAt)} · executable ${date(execAt)}` : ''}`;
  if (state === 3) p.className = 'preview warn';
}
async function executePlan(ev) {
  ev.preventDefault();
  const a = $('ex-addr').value.trim();
  if (!looksLikeAddress(a)) { toast('Enter a wallet.', 'bad'); return; }
  await send('Execute succession', () => write(D.successionRegistry, A.registryAbi, 'execute', [addr(a)]));
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
  if (!(await ensureAllowance(D.redemptionBuffer, maxIn, 'the buffer'))) return;
  await send('Buy inventory', () => write(D.redemptionBuffer, A.bufferAbi, 'buyInventory', [amount, maxIn]));
}
async function fillPot(ev) {
  ev.preventDefault();
  const amount = toWad($('fill-amount').value);
  if (amount === 0n) return;
  if (!(await ensureAllowance(D.redemptionBuffer, amount, 'the buffer'))) return;
  await send('Fill the pot', () => write(D.redemptionBuffer, A.bufferAbi, 'fill', [amount]));
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
    if (typeof v !== 'string' || !v.startsWith('0x')) continue;
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.innerHTML = NET.explorer ? `<a href="${NET.explorer}/address/${v}" target="_blank" rel="noopener">${v}</a>` : v;
    list.append(dt, dd);
  }

  $('btn-connect').addEventListener('click', connect);
  $('form-open').addEventListener('submit', openVault);
  $('form-adjust').addEventListener('submit', adjustVault);
  ['in-coll', 'in-debt'].forEach((id) => $(id).addEventListener('input', openPreview));
  ['adj-add-coll', 'adj-wd-coll', 'adj-borrow', 'adj-repay'].forEach((id) => $(id).addEventListener('input', adjustPreview));
  $('btn-close').addEventListener('click', () => send('Close vault', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'closeTrove')));
  $('btn-claim-surplus').addEventListener('click', () => send('Claim collateral', () => write(D.borrowerOperations, A.borrowerOperationsAbi, 'claimCollateral')));
  $('btn-faucet').addEventListener('click', () => send('Mint test wstETH', () => write(D.wstETH, A.wstAbi, 'mint', [me, 10n * WAD])));
  $('btn-approve').addEventListener('click', () => send('Approve wstETH', () => write(D.wstETH, A.erc20Abi, 'approve', [D.borrowerOperations, 2n ** 256n - 1n])));
  $('btn-add-heir').addEventListener('click', () => addHeirRow());
  $('form-plan').addEventListener('submit', savePlan);
  $('btn-prove').addEventListener('click', () => send('Prove life', () => write(D.successionRegistry, A.registryAbi, 'proveLife')));
  $('btn-clear-plan').addEventListener('click', () => send('Remove plan', () => write(D.successionRegistry, A.registryAbi, 'clearPlan')));
  $('form-operator').addEventListener('submit', saveOperator);
  $('form-execute').addEventListener('submit', executePlan);
  $('ex-addr').addEventListener('input', () => executePreview().catch(() => {}));
  $('form-redeem').addEventListener('submit', redeem);
  $('form-buy').addEventListener('submit', buyInventory);
  $('buy-amount').addEventListener('input', () => buyPreview().catch(() => {}));
  $('form-fill').addEventListener('submit', fillPot);
  $('btn-sp-deposit').addEventListener('click', () => { const a = toWad($('sp-amount').value); if (a > 0n) send('Deposit to the pool', () => write(D.stabilityPool, A.stabilityPoolAbi, 'provideToSP', [a, zeroAddress])); });
  $('btn-sp-withdraw').addEventListener('click', () => { const a = toWad($('sp-amount').value); if (a > 0n) send('Withdraw from the pool', () => write(D.stabilityPool, A.stabilityPoolAbi, 'withdrawFromSP', [a])); });
  $('btn-sp-claim').addEventListener('click', () => send('Claim pool gain', () => write(D.stabilityPool, A.stabilityPoolAbi, 'withdrawFromSP', [0n])));

  if ($('heir-rows').children.length === 0) addHeirRow();
  await refresh();
  refreshTimer = setInterval(() => refresh().catch(() => {}), 15000);
  if (window.ethereum && (await window.ethereum.request({ method: 'eth_accounts' })).length) connect();
}
boot().catch((e) => { console.error(e); toast(`Could not start: ${e.message}`, 'bad'); });
