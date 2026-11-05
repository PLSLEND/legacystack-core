# LegacyStack core

**Unaudited. Testnet only. Work in progress.** Do not deploy to mainnet. Do not send real funds to any
address produced by this code.

An immutable borrowing protocol on Ethereum: wstETH vaults, a fixed-rate loan unit (OCT), a revenue-funded
Redemption Buffer, and succession built into the vault. No admin keys over anything economic; the only
owner-like call is the one-time `setAddresses` wiring, which renounces itself.

Lineage: Liquity V1 (MIT). `src/upstream` is the Liquity code with the changes listed in
`docs/CHANGES_FROM_UPSTREAM.md`; `src/legacystack` is new.

## What is in here

| Path | Content |
|---|---|
| `src/upstream/` | Liquity V1 core (TroveManager, BorrowerOperations, StabilityPool, pools, SortedTroves, OCT token, HintHelpers, MultiTroveGetter), modified |
| `src/legacystack/PriceFeed.sol` | wstETH/USD = Chainlink ETH/USD × Lido `stEthPerToken()`, breakers, reduce-only state, self-healing, no keys |
| `src/legacystack/RedemptionBuffer.sol` | the wstETH pot: fee and interest recipient, buffer-first redemptions, standing offer at par + 0.5%, debt ceiling |
| `src/legacystack/SuccessionRegistry.sol` | heirs by basis points, one-year liveness, 30-day return window, settlement at par, push delivery, escrow, operator rights |
| `src/testnet/` | testnet-only contracts: wstETH with a faucet, Chainlink mock, issuance stub |
| `script/Deploy.s.sol` | full deployment and wiring, writes `deployments/<chainId>.json` |
| `test/` | Foundry tests (51): upstream smoke, interest index, collateral flows, price feed, buffer, succession |
| `docs/` | the testnet frontend (GitHub Pages) and the audit map |
| `frontend/` | frontend source (viem, no framework), bundled into `docs/app.js` |

## Build and test

Foundry with solc 0.6.11 (core) and 0.8.28 (tests, scripts, testnet contracts); versions are auto-detected.

```
forge install foundry-rs/forge-std --no-git
forge build
forge test
```

## Deploy to a test network

```
export ETH_USD_AGGREGATOR=0x694AA1769357215DE4FAC081bf1f309aDC325306   # Chainlink ETH/USD on Sepolia
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $PK
cd frontend && npm install && node build.mjs 11155111                    # bundles the app and copies the addresses into docs/
```

Without `ETH_USD_AGGREGATOR` the script deploys a mock aggregator at $3,000 (local chains). The deployer
opens a small seed vault and parks 1 OCT in the Stability Pool so the pool never sits at zero.

## Design in one paragraph

Borrowers deposit wstETH and mint OCT at a fixed 1.5% a year (global debt index; interest is minted to the
buffer at every touch), 110% minimum collateral ratio, 0.5% mint fee, Liquity liquidations through the
Stability Pool. Redemptions (0.75% floor, 5,000 OCT minimum) are served by the Redemption Buffer first and
reach user vaults only when it is empty; the buffer holds every fee and sells its OCT inventory back at par
plus 0.5%, and it sets the debt ceiling ($1M + $100 per $1 in the pot). The oracle has no keys: when
Chainlink or Lido misbehave the protocol goes reduce-only (repay, add collateral, close and liquidate at the
last good price stay open) and heals by itself. Succession: the owner names heirs; a year without an
owner-key action plus thirty days of grace lets anyone settle the vault at par and push collateral, OCT and
Stability Pool holdings to the heirs' wallets.

## Wording

OCT is the loan unit: it is borrowed and repaid. It is not described as a stablecoin, a payment instrument or
an investment anywhere in this repository or on the testnet page.
