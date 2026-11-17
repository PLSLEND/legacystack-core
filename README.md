# LegacyStack core

**Unaudited. Testnet only. Work in progress.** Do not deploy to mainnet. Do not send real funds to any
address produced by this code.

LegacyStack is an immutable borrowing protocol on Ethereum: a fixed 1.5% a year credit line against staked
ether (wstETH), with succession built into the vault. No admin keys, no governance over positions, no
middleman. OCT is its loan unit (minted when a user borrows, burned when the user repays, redeemable for a
dollar's worth of wstETH less the redemption fee; never a stablecoin). The only owner-like call is the one-time
`setAddresses` wiring, which renounces itself.

**For agents, wallets and integrators:** read `docs/agent.md` (what it is, what can never change, the numbers,
the risks in order, how to use it safely), `docs/llms.txt` and the generated `docs/.well-known/legacystack.json`
(constants, invariants, risks and the current addresses). The strategy the protocol implements, with the rules
a careful user or an agent can adopt, is `docs/playbook.html`. A read-only MCP server and agent skills live in
`agent/`.

**Risks, in order:** liquidation under a 110% collateral ratio with no margin call and no cure period;
redemptions when OCT trades below a dollar (the reserve serves first, then the lowest-ratio vaults, whose debt
and collateral shrink by the same value); an oracle that pauses new borrowing when degraded and winds the
deployment down after thirty days without a price; immutable code that cannot be patched, unaudited while this
line stands; succession that is final once a year of silence and thirty days of grace have passed. The frontend
does not serve persons in the United States.

Lineage: Liquity V1 (MIT). `src/upstream` is the Liquity code with the changes listed in
`docs/CHANGES_FROM_UPSTREAM.md`; `src/legacystack` is new.

## What is in here

| Path | Content |
|---|---|
| `src/upstream/` | Liquity V1 core (TroveManager, BorrowerOperations, StabilityPool, pools, SortedTroves, OCT token, HintHelpers, MultiTroveGetter), modified |
| `src/legacystack/PriceFeed.sol` | wstETH/USD = Chainlink ETH/USD × Lido `stEthPerToken()`, breakers, reduce-only state, self-healing, no keys |
| `src/legacystack/RedemptionBuffer.sol` | the Redemption Reserve: fees and the protocol's share of the staking yield, reserve-first redemptions, standing offer at par + 0.5%, debt ceiling, reserve deposits with fee sharing, the surplus waterfall, payout of inherited deposits |
| `src/legacystack/SuccessionRegistry.sol` | heirs by basis points, one proof of life a year, 30-day grace, settlement (estate OCT, reserve at par + 0.5%, Stability Pool at par + 2%), push delivery to the heirs' wallets, escrow |
| `src/periphery/` | ownerless periphery, replaceable per deployment: keeper desk, liquidity desk (band, bids, asks), interest splitter and issuance (the interest to the Stability Pool's depositors and the bids, in OCT), burn auction, surplus splitter, POL keeper (Uniswap v3 testnet flavour), reserve rewards |
| `src/testnet/` | testnet-only contracts: wstETH with a faucet, test USDe and STACK, Chainlink and Chronicle mocks |
| `script/Deploy.s.sol` | full deployment and wiring, writes `deployments/<chainId>.json` |
| `test/` | Foundry tests (99): upstream smoke, interest index, collateral flows, price feed, reserve and fee sharing, succession, auto-repay and the yield share, keeper desk, sinks, liquidity desk, the interest route |
| `docs/` | the testnet frontend (GitHub Pages), the playbook, the agent brief (`agent.md`, `llms.txt`, `.well-known/legacystack.json`) and the audit map |
| `agent/` | a read-only MCP server against the current deployment and agent skills (see `agent/README.md`) |
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

Borrowers deposit wstETH and mint OCT at a fixed 1.5% a year (global debt index; the interest is minted at
every touch and paid half to the Stability Pool's depositors and half to the dollars resting under par in the
market pool, in OCT), 110% minimum collateral ratio, 0.5% mint fee, Liquity liquidations through the
Stability Pool. Redemptions (0.75% floor, 5,000 OCT minimum) are served by the Redemption Buffer first and
reach user vaults only when it is empty; the buffer holds the fees and the protocol's share of the staking
yield (15% of a vault's yield, 10% with auto-repay on), sells its OCT inventory back at par plus 0.5%, and
sets the debt ceiling ($1M + $100 per $1 in the pot). There are no STACK emissions: STACK is only bought back
and burned from the reserve's surplus. The oracle has no keys: when
Chainlink or Lido misbehave the protocol goes reduce-only (repay, add collateral, close and liquidate at the
last good price stay open) and heals by itself. Succession: the owner names heirs; a year without an
owner-key action plus thirty days of grace lets anyone settle the vault at par and push collateral, OCT and
Stability Pool holdings to the heirs' wallets.

## Wording

OCT is the loan unit: it is borrowed and repaid. It is not described as a stablecoin, a payment instrument or
an investment anywhere in this repository or on the testnet page.
