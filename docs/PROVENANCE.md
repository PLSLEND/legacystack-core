# Provenance

- `src/upstream/*`: copied verbatim from https://github.com/liquity/dev, `packages/contracts/contracts`,
  commit recorded in `UPSTREAM_COMMIT.txt`. Files carry `SPDX-License-Identifier: MIT`.
  Excluded: LQTY token, LQTY staking, lockup contracts, LP rewards, proxies, integrations, migrations.
- `test/upstream-mocks/*`: Liquity test helpers (MIT), import paths adjusted.
- Every change to `src/upstream` after the first commit is listed in `docs/CHANGES_FROM_UPSTREAM.md`
  with the reason and the LS_06 decision number.
