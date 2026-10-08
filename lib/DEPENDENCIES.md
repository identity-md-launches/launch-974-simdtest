# Vendored dependencies

All compilation inputs are ordinary files; no submodules or network fetches are needed.

- `v4-core/src/` (excluding upstream test helpers) and `v4-core/licenses/`: Uniswap v4-core v4.0.0, commit `e50237c43811bd9b526eff40f26772152a42daba`, from https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba . Unmodified. SPDX MIT or BUSL-1.1 as indicated per file; license texts included.
- `solmate/src/auth/Owned.sol` and `solmate/LICENSE`: commit `4b47a19038b798b4a33d9749d25e570443520647`, from https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647 . Unmodified. AGPL-3.0-only; required only by the upstream PoolManager used in local integration tests. The launch token and hook do not inherit this ownership contract or deploy a PoolManager.

The production hook uses v4 interfaces, data types and hook permission validation. Tests deploy the real v4 PoolManager locally.
