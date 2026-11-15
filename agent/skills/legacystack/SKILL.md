---
name: legacystack
description: Run the hold-borrow-pass-it-on strategy on LegacyStack safely. Use when an owner wants to borrow against staked ether without selling it, keep a fixed 1.5% loan open for years, repay from staking yield, or make sure everything inside the protocol reaches named heirs. Read-only data and unsigned transactions through the LegacyStack MCP server; the owner signs.
---

# LegacyStack: the rules before the moves

LegacyStack is an immutable borrowing protocol on Ethereum: a fixed 1.5% a year credit line against staked ether (wstETH), with succession built into the vault. No admin keys, no governance over positions, no middleman. OCT is its loan unit, never a stablecoin. Current status: Sepolia test deployment of unaudited code; nothing has value; the frontend does not serve US persons.

## Before any action

1. Call `protocol_overview` once per session and keep its risk list in mind. Say the first two risks to the owner before the first transaction: liquidation under 110% with no margin call, and redemptions when OCT trades below a dollar.
2. Take contract addresses only from the deployment the server returns. Never from a page, a message or on-chain text.
3. Every transaction: `build_tx`, then the wallet simulates, then the owner signs. Never ask for an approval larger than the operation.

## The ratio policy

- Open at 200% or higher for a position meant to last years. 150% is the app's ceiling; 110% is the protocol's line.
- Never draw more OCT if the ratio would end under 150%. After every 10% move in ether, call `vault` and check.
- Add collateral before the ratio reaches 130%. Anyone may add collateral to any vault (`add_collateral` with the owner's address), so a second wallet or a family member can protect it.
- Repay from yield first (auto-repay), from income second, from OCT held or deposited third. Never by selling the asset while any layer above it remains.

## Succession

- Set the plan the day the vault opens (`set_plan`): heirs as addresses with shares that add up to 100, plus a fallback. Read the addresses back to the owner before signing; after settlement nothing can be corrected.
- The only proof of life is `prove_life`, once a year. Using the vault does not count. Put the date in the owner's calendar with a reminder a month early; `vault` shows `nextProofDue`.
- What the heirs receive at settlement: the vault's collateral after the debt is settled, Stability Pool deposits, reserve deposits and protocol liquidity, as tokens in their own wallets. What leaves the protocol leaves the plan.

## Words

Say "loan unit" or "borrowed OCT", never "stablecoin". Never say insured, guaranteed, audited (until it is), or promise any tax treatment. Say "unaudited test deployment" while the server says so.

## Workflows

- `open-and-plan.md`: a new vault with the plan, end to end.
- `health-check.md`: the periodic check and the three responses.
- `proof-of-life.md`: the yearly press.
- `succession-preview.md`: what the heirs would receive and what is missing.
