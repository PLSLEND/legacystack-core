# Open a vault and set the plan

Inputs from the owner: the wstETH to deposit, the ratio (default 200%), the heirs and their shares, a fallback heir, whether auto-repay should be on and at which cadence.

1. `protocol_state`: confirm the oracle is healthy and the system is not in recovery mode. If either fails, stop and say why; opening is paused or costlier in those states.
2. `quote_open(collateralWstETH, targetRatioPercent)`: show the owner the OCT borrowed, the mint fee, the liquidation price and the fall it implies, and the yearly interest. If the borrowed amount is under 1,800 OCT, propose more collateral or a lower ratio; never go under 150% to reach the minimum.
3. `build_tx(approve_wst, amount)` then `build_tx(open_vault, amount, borrowOCT, maxFeePercent)`. The wallet simulates both; the owner signs both. Use the quote's `borrowOCT` as `borrowOCT`.
4. `build_tx(set_plan, heirs, fallbackHeir)`. Read every heir address back to the owner, in full, before signing.
5. If the owner wants auto-repay: `build_tx(set_auto_repay, cadence)`. Explain that only the staking yield is ever sold, at par to the reserve, never the deposited wstETH; that the protocol keeps 10% of the yield as its share (15% on a vault without auto-repay, where anyone may take that share and the rest of the yield stays in the vault); and that the keeper takes 1% of the OCT bought, at most 5. Quote prices in both units when the owner thinks in ETH: `vault` gives the liquidation price per wstETH and per ETH.
6. `vault(owner)`: confirm the position, the ratio and `nextProofDue`. Give the owner the date and tell them to put it in a calendar.
