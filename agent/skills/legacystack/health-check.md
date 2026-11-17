# Health check

Run after every 10% move in ether, and at least monthly.

1. `vault(owner)`: read the ratio, the liquidation price, `nextProofDue` and `inheritedWaitingWstETH`.
2. Three responses, in order of preference:
   - Ratio at or above 150%: nothing to do. Note the ratio and the date.
   - Ratio under 150% and above 130%: propose `add_collateral` (from the owner or from any helper wallet) to bring it back above 200%; or propose `repay` from OCT the owner holds, from the Stability Pool (`withdraw_from_stability_pool` first, which also pays out the OCT income), or with wstETH through the reserve (`repay_from_reserve`, par + 0.5%, when the owner holds no OCT). Repaying from the yield is already happening if auto-repay is on.
   - Ratio under 130%: act now, not later. Add collateral first, repay second. Say plainly that under 110% the vault is liquidated with no warning.
3. If `nextProofDue` is within 60 days, say so and offer `prove_life`.
4. If `inheritedWaitingWstETH` is above zero, the owner is an heir with a payout waiting; `build_tx(finish_inherited_payout, owner)` pays it out once the reserve can spare it (the call reverts while it cannot; `keeper_pending` shows whether payouts are payable).
5. Never propose selling the collateral while the owner has income, OCT in hand or unused borrowing room above 200%.
