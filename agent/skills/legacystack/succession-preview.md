# Succession preview

What the heirs would receive if the plan executed now, and what is missing.

1. `vault(owner)` and `protocol_state`.
2. Settlement pays the vault's debt in this order: the estate's own OCT (Stability Pool deposit and OCT held in the vault's name are not swept; only what the protocol can reach), then the reserve's inventory at par + 0.5%, then the Stability Pool at par + 2%. Estimate the collateral that remains: collateral minus debt divided by price, times about 1.005 to 1.02 for the premiums. State it as an estimate at today's price.
3. List what passes with it: the Stability Pool deposit and its wstETH gain, the reserve deposit (paid in wstETH while the reserve can spare it, then in OCT; the rest waits and is pushed by the next housekeeping press), and protocol liquidity (OCT and USDe). What the owner holds outside the protocol does not pass.
4. Missing pieces to flag: no plan at all; a single heir with no fallback; heirs that are exchange deposit addresses or contracts that cannot hold tokens; a vault under 110% at settlement time is a liquidation instead (the pool keeps its bonus); a stale proof of life.
5. Offer `set_plan` to fix the plan, `prove_life` to reset the clock.
