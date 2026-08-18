# MOLA GAMES on-chain game economy

`game_economy` is the production-candidate Sui Move package for one game's
closed-loop economy. It contains only the on-chain assets:

- `GAME_CREDIT` (symbol `M`): a two-decimal closed-loop `Token` rewarded by an
  authorized backend and consumed by exact-price catalog purchases.
- SUI: independently deposited into a reward vault and paid only by the
  dedicated SUI reward authority.

XP and soft currency remain off-chain. There is no CLT/SUI conversion,
redemption, swap, exchange rate, liquidity pool, or freely transferable CLT
substitute.

The final modules are `game_credit`, `platform`, `reward`, `product_catalog`,
`purchase`, `supply`, and `sui_reward`. Sensitive framework authority is nested
inside the key-only `Treasury`; `AdminCap`, `RewardCap`, and `SuiRewardCap` are
also key-only and have explicit transfer functions. The official
`TokenPolicy<GAME_CREDIT>` permits only the package-private purchase rule.

Fresh publication creates an empty product catalog and zero token supply. The
deployer must create products explicitly and, after publish, complete the Sui
coin-registry registration described in
[TESTNET_DEPLOYMENT.md](TESTNET_DEPLOYMENT.md).

```bash
sui move build --build-env testnet --warnings-are-errors
sui move test --build-env testnet --warnings-are-errors
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the ownership and attack-surface
model and [TESTNET_DEPLOYMENT.md](TESTNET_DEPLOYMENT.md) for the verified Sui
CLI 1.76.1 Testnet workflow.
