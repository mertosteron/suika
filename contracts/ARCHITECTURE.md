# Game economy architecture

## Scope and economic separation

This package implements one game's on-chain closed-loop token (`GAME_CREDIT`,
symbol `M`) and an independent pre-funded SUI reward vault. XP and soft
currency are backend state. No function exchanges, redeems, swaps, or converts
CLT and SUI, and the token policy does not permit unrestricted transfers or
conversion to `Coin<GAME_CREDIT>`.

CLT lifecycle:

```text
RewardCap + Treasury mint -> player Token<GAME_CREDIT>
-> exact catalog purchase -> TokenPolicy spent balance
-> RewardCap + Treasury flush -> total supply reduction
```

SUI lifecycle:

```text
funding Coin<SUI> -> shared SuiRewardVault
-> SuiRewardCap-authorized payout -> winner Coin<SUI>
```

## Modules

| Module | Responsibility |
|---|---|
| `game_credit` | Currency registration, official closed-loop policy, protected treasury, package-private mint/spend/flush primitives. |
| `platform` | Key-only `AdminCap`, global pause, and CLT-spending pause. |
| `reward` | Key-only CLT `RewardCap`, bounded rewards, CLT-specific pause, and reward-ID replay set. |
| `product_catalog` | Empty-on-publish catalog, product administration, limits, counters, and order replay set. |
| `purchase` | Exact-price CLT purchase and backend fulfillment event. |
| `supply` | Authorized full spent-balance flush and cumulative burn accounting. |
| `sui_reward` | Key-only SUI reward authority, permissionless non-zero funding, bounded payouts, pause, and replay state. |

All module initializers execute once during package publication. This repository
has no `Published.toml` and no prior package identity, so its intended Testnet
deployment is a fresh version-1 publication, not an upgrade or migration.

## Capabilities and abilities

| Object | Abilities | Initial/normal owner | Transfer path | Authority |
|---|---|---|---|---|
| `AdminCap` | `key` only | Deployer; later cold admin/multisig | `platform::transfer_administration` only | Pauses, reward limits, and product configuration. No mint, flush, policy-cap, treasury, or SUI payout authority. |
| `RewardCap` | `key` only | Deployer; normally CLT backend | `reward::transfer_reward_authority`, together with `Treasury` | Bounded CLT mint and complete spent-balance flush when the paired `Treasury` is also supplied. |
| `SuiRewardCap` | `key` only | Deployer; normally separate SUI backend | `sui_reward::transfer_sui_reward_authority` only | Bounded payout from pre-funded SUI only. No CLT authority. |
| `Treasury` | `key` only | Deployer; normally same custody as `RewardCap` | Package-private transfer invoked only by the reward-authority rotation | Wraps `TreasuryCap<GAME_CREDIT>` and `TokenPolicyCap<GAME_CREDIT>`; neither can be extracted. |

The absence of `store` on all four objects prevents generic public transfer,
wrapping, or sharing. They cannot be copied or dropped. Framework capabilities
retain their framework-defined abilities but are private fields of `Treasury`,
so external code cannot access them.

## Persistent objects and ownership

| Object | Ownership | Access and mutation | Contention |
|---|---|---|---|
| `AdminCap` | Address-owned | Consumed only for explicit rotation; borrowed by admin calls. | None unless the same cap is used concurrently. |
| `RewardCap` | Address-owned | Borrowed by CLT reward/flush; consumed for rotation. | Owned-object sequencing at the backend. |
| `SuiRewardCap` | Address-owned | Borrowed by SUI payouts; consumed for rotation. | Owned-object sequencing at the SUI backend. |
| `Treasury` | Address-owned | Mutated for mint/flush; consumed for rotation. | Serializes CLT mint and flush operations for its owner. |
| `Currency<GAME_CREDIT>` | Shared after coin-registry finalization | Read for metadata/registry queries. Metadata cap is permanently deleted. | No application mutation. |
| `TokenPolicy<GAME_CREDIT>` | Shared | `&mut` on every purchase and flush because official spent balance changes. | Serializes CLT spending and spent-balance flushing. |
| `PlatformConfig` | Shared | `&` on protected flows; `&mut` for global/spending pause changes. | Pause changes contend; normal reads can use the immutable shared-object path. |
| `RewardConfig` | Shared | `&` on rewards; `&mut` for pause/limit administration. | Configuration updates contend; reward reads do not mutate it. |
| `RewardRegistry` | Shared | `&mut` on every CLT reward for global replay protection. | Serializes CLT reward replay registration. |
| `ProductCatalog` | Shared | `&mut` for administration and purchases. | Serializes catalog writes and purchase/order accounting. |
| `SupplyStats` | Shared | `&mut` only during a flush. | Flush-only contention. |
| `SuiRewardConfig` | Shared | `&` on payouts; `&mut` for pause/limit administration. | Configuration updates contend. |
| `SuiRewardVault` | Shared | `&mut` for deposits and payouts. | Serializes vault balance and SUI reward replay updates. |

`Table` values are dynamic fields under `RewardRegistry`, `ProductCatalog`, and
`SuiRewardVault`. They hold only replay IDs, products, and per-player counts;
there is no game registry or generic game identifier.

## State invariants

- Initial CLT supply, catalog size, spent balance, cumulative burn count, replay
  counts, and SUI vault balance are zero.
- CLT and SUI rewards require non-zero amounts, a 32-byte unique ID, an
  unpaused platform/domain, and the configured maximum.
- A SUI payout also requires existing vault balance; the vault cannot mint SUI.
- Products have unique IDs and non-zero prices. Zero limit means unlimited.
- Purchase validation checks platform state, product activity, global and
  player limits, order replay, non-zero exact payment, and sender identity.
- Purchase counters and order replay state are committed only after official
  policy confirmation consumes the payment.
- A flush burns the entire non-zero policy spent balance and increments
  cumulative burn accounting by exactly that amount.
- Sui transaction atomicity rolls back replay, counters, balances, supply, and
  events whenever any assertion aborts.

## Events

Backend/operations events retained in the final bytecode are:

- `PlatformPauseChanged`, `CltSpendingPauseChanged`,
  `AdministrationTransferred`
- `CltRewarded`, `CltRewardsPauseChanged`, `MaxCltRewardChanged`,
  `RewardAuthorityTransferred`
- `ProductCreated`, `ProductPriceUpdated`, `ProductStatusUpdated`,
  `ProductLimitsUpdated`
- `PurchaseCompleted`
- `CltSpentFlushed`
- `SuiVaultFunded`, `SuiRewarded`, `SuiRewardsPauseChanged`,
  `MaxSuiRewardChanged`, `SuiRewardAuthorityTransferred`

## Public mutation attack surface

| Function | Required authority | State mutated | Economic effect | Replay | Pause |
|---|---|---|---|---|---|
| `platform::transfer_administration` | Owned `AdminCap` | Capability ownership | Rotates admin custody | N/A | N/A |
| `platform::{pause,unpause}_platform` | `&AdminCap` | `PlatformConfig` | Gates CLT rewards, purchases, and SUI rewards | N/A | Control itself |
| `platform::{pause,unpause}_clt_spending` | `&AdminCap` | `PlatformConfig` | Gates purchases only | N/A | Control itself |
| `reward::transfer_reward_authority` | Owned `RewardCap` and `Treasury` | Both owned objects | Rotates CLT mint/flush custody together | N/A | N/A |
| `reward::reward_player` | `&RewardCap` plus mutable owned `Treasury` | `Treasury`, `RewardRegistry` | Mints bounded CLT to recipient | 32-byte global CLT reward ID | Global + CLT reward |
| `reward::{pause,unpause}_clt_rewards` | `&AdminCap` | `RewardConfig` | Gates CLT mint rewards | N/A | Control itself |
| `reward::update_max_reward_per_transaction` | `&AdminCap` | `RewardConfig` | Changes per-call CLT mint ceiling | N/A | N/A |
| `product_catalog::create_product` | `&AdminCap` | `ProductCatalog` | Adds active purchasable product | Unique product ID | N/A |
| `product_catalog::update_product_price` | `&AdminCap` | `ProductCatalog` | Changes future exact payment | N/A | N/A |
| `product_catalog::{enable,disable}_product` | `&AdminCap` | `ProductCatalog` | Enables/disables future purchases | N/A | N/A |
| `product_catalog::update_product_limits` | `&AdminCap` | `ProductCatalog` | Changes future sales/player ceilings | N/A | N/A |
| `purchase::purchase_catalog_product` | Sender-owned `Token<GAME_CREDIT>`; private policy rule | `ProductCatalog`, `TokenPolicy` | Irreversibly moves exact CLT to spent balance | 32-byte global order ID | Global + CLT spending |
| `supply::flush_spent_tokens` | `&RewardCap` plus mutable owned `Treasury` | `TokenPolicy`, `SupplyStats`, `Treasury` | Burns complete spent CLT balance | N/A; balance consumed | N/A |
| `sui_reward::transfer_sui_reward_authority` | Owned `SuiRewardCap` | Capability ownership | Rotates SUI payout custody | N/A | N/A |
| `sui_reward::deposit_sui` | Caller-supplied non-zero `Coin<SUI>` | `SuiRewardVault` | Irrevocably adds prefunded SUI | N/A | Deposits remain available |
| `sui_reward::reward_player` | `&SuiRewardCap` | `SuiRewardVault` | Transfers bounded prefunded SUI | 32-byte global SUI reward ID | Global + SUI reward |
| `sui_reward::{pause,unpause}_sui_rewards` | `&AdminCap` | `SuiRewardConfig` | Gates SUI payouts | N/A | Control itself |
| `sui_reward::update_max_reward_per_transaction` | `&AdminCap` | `SuiRewardConfig` | Changes per-call SUI payout ceiling | N/A | N/A |

There are no production `entry` functions. Public functions are intentionally
composable in a PTB; type checking and Sui object ownership enforce capability
boundaries before execution. No public function exposes or changes policy rules,
extracts framework caps, withdraws arbitrary SUI, or creates another capability.

## Upgrade model

The first canonical Testnet publication is version 1. Publication creates an
address-owned `UpgradeCap`; package upgrades must use the generated
`Published.toml`, the original package identity, and the selected on-chain
upgrade policy. This source contains no unpublished-version migration state or
compatibility endpoints. Future upgrades must separately assess Sui layout and
linkage compatibility before changing any on-chain type or public signature.
