# The yearly proof of life

The plan executes after 365 days without the proof-of-life button, plus 30 days of grace. Nothing else resets the clock: not a repayment, not a deposit, not a transfer.

1. `vault(owner)`: read `lastProofOfLife`, `nextProofDue`, `executableFrom` and the plan state.
2. If the state is `alive` or `due`: `build_tx(prove_life)`; the owner signs. Then `vault` again and confirm the new `nextProofDue`.
3. If the state is `executable`: the owner is still in time; press now, explain what happens 30 days after the due date otherwise.
4. If the state is `executed`: the estate has been settled; nothing can be undone. Report what happened and where the assets went (the heirs' wallets).
5. Put the next date in the calendar with a reminder a month early. Owners who travel or hold the key in a safe should press early rather than late; pressing twice costs nothing but gas.
