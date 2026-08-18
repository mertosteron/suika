# Game Economy Architecture Test Specification

| Field | Value |
|---|---|
| Phase | 0 — Architecture Test Specification only |
| Reviewed | 2026-08-18 |
| Contract package | `game_economy` |
| Reviewed contract revision | `d5a30ae1b698de8cd7f8a4dc668cbd5b25d55b79` (`main`) |
| Recorded Testnet package | `0x1284f91b7fcf1355bf87592d0b3892af43828c4cb0a736f18609f43690ca2e5f`, version 1 |
| Scope boundary | This document specifies Phase 1 work. It does not implement gameplay, a frontend, a backend, a database, blockchain integration, deployment actions, or contract changes. |

## 1. Purpose

This specification defines a deliberately small Suika-style browser game that will exercise the existing hybrid game economy in a realistic environment. The game is a test harness for architecture, not a production balancing exercise.

The validation target is the complete boundary between:

- off-chain browser gameplay;
- backend-authoritative XP and Soft Currency;
- the existing closed-loop `Token<GAME_CREDIT>` reward and purchase lifecycle;
- the independent pre-funded SUI reward lifecycle;
- backend synchronization from final Sui transaction effects and events;
- replay, pause, capability, failure, atomicity, adaptability, and contention behavior.

The existing Move package is the on-chain source of truth. This specification adapts the future game and backend to its actual types and functions. No smart contract change is required before Phase 1 based on the present review.

Review evidence:

- all seven production modules and all seven Move test modules were inspected;
- `ARCHITECTURE.md`, `README.md`, `TESTNET_DEPLOYMENT.md`, `Move.toml`, `Move.lock`, `Published.toml`, deployment environment files, and build metadata were inspected;
- `sui move test --build-env testnet --warnings-are-errors` passes 89 of 89 tests with Sui CLI `1.76.1-433212f8f276`;
- contract source was not modified.

## 2. Existing Architecture Summary

### 2.1 Actual modules

| Module | Existing responsibility |
|---|---|
| `game_credit` | Defines `GAME_CREDIT`, registers the two-decimal currency (`M`, “Mola Token”), creates the official `TokenPolicy`, wraps `TreasuryCap<GAME_CREDIT>` and `TokenPolicyCap<GAME_CREDIT>` inside `Treasury`, and exposes only package-private mint, purchase-consumption, transfer-for-rewards, supply, and flush primitives. |
| `platform` | Creates key-only `AdminCap` and shared `PlatformConfig`; controls the global platform pause and CLT-spending pause. |
| `reward` | Creates key-only `RewardCap`, shared `RewardConfig`, and shared `RewardRegistry`; provides bounded, paused, replay-protected CLT rewards and paired rotation of `RewardCap` with `Treasury`. |
| `product_catalog` | Creates the shared empty `ProductCatalog`; stores products, wallet/product counts, global sold counts, and globally processed purchase order IDs. |
| `purchase` | Accepts an exact `Token<GAME_CREDIT>` payment for one active catalog product, confirms the private purchase policy rule, commits counters/replay state, and emits `PurchaseCompleted`. |
| `supply` | Creates shared `SupplyStats`; flushes the complete non-zero official policy spent balance and records cumulative burned CLT. |
| `sui_reward` | Creates key-only `SuiRewardCap`, shared `SuiRewardConfig`, and shared `SuiRewardVault`; accepts permissionless non-zero SUI funding and performs bounded, paused, replay-protected payouts from that balance. |

There are no production `entry` functions. The production transaction endpoints are `public` functions and are composable in Sui Programmable Transaction Blocks (PTBs).

### 2.2 `GAME_CREDIT`, treasury, and policy

`GAME_CREDIT` is not implemented as a freely transferable `Coin<GAME_CREDIT>`. Players receive `0x2::token::Token<GAME_CREDIT>` objects.

The currency has:

- 2 decimals;
- symbol `M`;
- name `Mola Token`;
- zero initial supply;
- finalized coin-registry metadata with its metadata capability deleted;
- no regulated-currency deny cap.

`game_credit::Treasury` is a key-only, address-owned object containing private fields:

- `TreasuryCap<GAME_CREDIT>`;
- `TokenPolicyCap<GAME_CREDIT>`.

Neither framework capability can be extracted by external code. `Treasury` has no `store`, so it cannot be generically transferred, wrapped, shared, copied, or dropped. Its only supported transfer path is the package-private call used by `reward::transfer_reward_authority`.

The shared `TokenPolicy<GAME_CREDIT>` allows the spend action only when the package-private `GamePurchaseRule` is approved. Normal token transfer, conversion to `Coin<GAME_CREDIT>`, and conversion from `Coin<GAME_CREDIT>` are not allowed. The protected policy cap is used internally to deliver newly minted reward tokens; players cannot use it.

The actual closed-loop lifecycle is:

```text
RewardCap + mutable Treasury
  -> reward::reward_player
  -> player Token<GAME_CREDIT>
  -> exact product purchase through GamePurchaseRule
  -> TokenPolicy spent balance
  -> RewardCap + mutable Treasury + SupplyStats flush
  -> total supply reduction
```

There is no redeem, swap, exchange-rate, liquidity, or CLT-to-SUI function.

### 2.3 Capabilities and root authority

| Capability/object | Abilities and creation | Actual authority | Phase 1 custody assumption |
|---|---|---|---|
| `UpgradeCap` | Framework-created, address-owned at publication | Can authorize compatible package upgrades and therefore supersedes all application-level controls. | Cold operator security/multisig; never held by an application worker. |
| `platform::AdminCap` | `key` only; created in `platform::init` | Platform and CLT-spending pauses; CLT/SUI reward domain pauses and maxima; catalog create/price/status/limit administration. Cannot mint, flush, or pay SUI. | Operator/admin custody, preferably cold or multisig with a controlled admin relay. |
| `reward::RewardCap` | `key` only; created in `reward::init` | Authorizes CLT reward minting and spent-token flushing, but only when the paired `Treasury` is also supplied. | Dedicated CLT Reward Service signer. |
| `game_credit::Treasury` | `key` only; created in `game_credit::init` | Holds the non-extractable treasury and policy caps used for CLT mint, protected delivery, and flush. | Same dedicated custody as `RewardCap`; the two rotate together. |
| `sui_reward::SuiRewardCap` | `key` only; created in `sui_reward::init` | Authorizes bounded payout from the pre-funded SUI vault. Has no CLT authority. | Separate SUI Reward Service signer. |

All application capabilities are initially transferred to the publisher by their module initializers. The deployment record identifies their object IDs, but live owner and object state must be re-queried from Testnet before Phase 1; a local environment file is not proof of current custody.

### 2.4 Persistent objects and mutation paths

| Object | Ownership | Production users | Mutation and contention implication |
|---|---|---|---|
| `AdminCap` | Address-owned, key-only | Admin calls and rotation | Low-volume owned-object sequencing. |
| `RewardCap` | Address-owned, key-only | CLT reward, CLT flush, rotation | A common owned input for CLT service calls. |
| `Treasury` | Address-owned, key-only | CLT reward, CLT flush, rotation | Mutated for every CLT mint/flush; serializes those calls for its owner. |
| `SuiRewardCap` | Address-owned, key-only | SUI payout and rotation | Common owned input for SUI service calls. |
| `Currency<GAME_CREDIT>` | Shared after registry finalization | Metadata/registry reads | No application mutation. |
| `TokenPolicy<GAME_CREDIT>` | Shared | Every purchase and CLT flush | Mutable on both flows; a global spending/flush hotspot. |
| `PlatformConfig` | Shared | All CLT rewards, purchases, and SUI rewards; admin pause calls | Normal protected flows borrow it immutably; pause changes mutate it. |
| `RewardConfig` | Shared | CLT rewards; admin CLT reward configuration | Rewards read it; pause/maximum changes mutate it. |
| `RewardRegistry` | Shared | Every CLT reward | Mutated for the global 32-byte replay set; a global CLT reward hotspot. |
| `ProductCatalog` | Shared | Every purchase and every product administration call | Mutated for products, counters, and order replay; a global catalog/purchase hotspot. |
| `SupplyStats` | Shared | CLT flush | Mutated only during flush. |
| `SuiRewardConfig` | Shared | SUI rewards; admin SUI reward configuration | Rewards read it; pause/maximum changes mutate it. |
| `SuiRewardVault` | Shared | Every deposit and SUI payout | Mutated for the balance and SUI replay set; a global SUI reward hotspot. |
| Player `Token<GAME_CREDIT>` | Player address-owned | Player purchase PTB | Split by the player and consumed only through the approved exact-price purchase path. |

The replay/product/count collections are `Table` values stored as dynamic fields. `RewardRegistry.processed`, `ProductCatalog.processed_orders`, `ProductCatalog.products`, `ProductCatalog.player_purchase_counts`, and `SuiRewardVault.processed` have no pruning or epoch partitioning.

### 2.5 Production public mutation surface

| Function | Required authority/input | Effect |
|---|---|---|
| `platform::transfer_administration` | Owned `AdminCap` | Transfers admin authority and emits `AdministrationTransferred`. |
| `platform::pause_platform`, `unpause_platform` | `&AdminCap`, `&mut PlatformConfig` | Gates CLT rewards, purchases, and SUI rewards. |
| `platform::pause_clt_spending`, `unpause_clt_spending` | `&AdminCap`, `&mut PlatformConfig` | Gates purchases only. |
| `reward::transfer_reward_authority` | Owned `RewardCap` and `Treasury` | Transfers the paired CLT custody objects and emits `RewardAuthorityTransferred`. |
| `reward::reward_player` | `&RewardCap`, `&mut Treasury`, shared configs/registry | Mints and delivers bounded CLT using a unique 32-byte reward ID. |
| `reward::pause_clt_rewards`, `unpause_clt_rewards` | `&AdminCap`, `&mut RewardConfig` | Gates CLT rewards only. |
| `reward::update_max_reward_per_transaction` | `&AdminCap`, `&mut RewardConfig` | Changes the positive per-call CLT ceiling. |
| `product_catalog::create_product` | `&AdminCap`, `&mut ProductCatalog` | Adds a unique positive-price active product. |
| `product_catalog::update_product_price` | `&AdminCap`, `&mut ProductCatalog` | Changes the exact price for future purchases. |
| `product_catalog::enable_product`, `disable_product` | `&AdminCap`, `&mut ProductCatalog` | Changes future availability. |
| `product_catalog::update_product_limits` | `&AdminCap`, `&mut ProductCatalog` | Changes global/per-wallet limits without resetting history. |
| `purchase::purchase_catalog_product` | Sender-owned `Token<GAME_CREDIT>` and shared policy/catalog | Validates sender, product, exact payment, limits, and order replay; consumes CLT and emits the fulfillment event. |
| `supply::flush_spent_tokens` | `&RewardCap`, `&mut Treasury`, policy/stats | Burns the complete non-zero policy spent balance. |
| `sui_reward::transfer_sui_reward_authority` | Owned `SuiRewardCap` | Transfers SUI payout authority. |
| `sui_reward::deposit_sui` | Any non-zero `Coin<SUI>` | Irrevocably adds prefunded SUI; grants no authority or receipt. |
| `sui_reward::reward_player` | `&SuiRewardCap`, configs/vault | Pays bounded prefunded SUI using a unique 32-byte reward ID. |
| `sui_reward::pause_sui_rewards`, `unpause_sui_rewards` | `&AdminCap`, `&mut SuiRewardConfig` | Gates SUI payouts only. |
| `sui_reward::update_max_reward_per_transaction` | `&AdminCap`, `&mut SuiRewardConfig` | Changes the positive per-call SUI ceiling. |

### 2.6 Existing on-chain events

The future indexer must recognize these exact event types:

- platform/admin: `PlatformPauseChanged`, `CltSpendingPauseChanged`, `AdministrationTransferred`;
- CLT rewards: `CltRewarded`, `CltRewardsPauseChanged`, `MaxCltRewardChanged`, `RewardAuthorityTransferred`;
- catalog: `ProductCreated`, `ProductPriceUpdated`, `ProductStatusUpdated`, `ProductLimitsUpdated`;
- purchases: `PurchaseCompleted`;
- supply: `CltSpentFlushed`;
- SUI: `SuiVaultFunded`, `SuiRewarded`, `SuiRewardsPauseChanged`, `MaxSuiRewardChanged`, `SuiRewardAuthorityTransferred`.

The economic confirmation events carry:

| Event | Fields used by the backend |
|---|---|
| `CltRewarded` | `recipient`, `amount`, `reward_id` |
| `PurchaseCompleted` | `buyer`, `product_id`, `amount`, `order_id` |
| `SuiRewarded` | `recipient`, `amount`, `reward_id` |
| `SuiVaultFunded` | `amount`, `balance_after` |
| `CltSpentFlushed` | `amount`, `total_supply_after`, `total_burned` |

The transaction digest, checkpoint/order, event sequence, package ID, sender, and successful effects status are transaction metadata and must also be stored by the indexer.

### 2.7 Deployment state in the repository

The package is configured for Move edition 2024. `Move.lock` pins Testnet `MoveStdlib` and `Sui` to revision `d50b78880fdacb1bbde92e6974ed71a7650c1090`.

Contrary to pre-publication statements still present in `ARCHITECTURE.md` and early sections of `TESTNET_DEPLOYMENT.md`, the repository now contains:

- `Published.toml` for Testnet package version 1;
- package/original ID `0x1284f91b7fcf1355bf87592d0b3892af43828c4cb0a736f18609f43690ca2e5f`;
- UpgradeCap ID `0xb6b4d7e6ce73ca759ce83cfa89bd0ac36fbbea0d72616424386c2ab76e5af9fa`;
- an ignored `deployments/testnet.env` containing public package, capability, shared-object, publish, and currency-registration identifiers;
- a recorded publish commit dated 2026-08-14.

The recorded environment uses Testnet chain ID `4c78adac`, deployer `0xbf8dcdc04370f79d517fed2846cdd47ecef9ff02b4dd1c1bb79c42acb86113ec`, publish digest `6ZDw56yJ4AgBFHnyaQYq6meVPFAVRyfuCaXRHcJG9Dit`, and currency-registration digest `4JfYF51QnsCbvAfjtexWN4zmL6c7TRY1T9Mi3PziHeKN`. Its public object IDs are:

| Environment key | Recorded object ID |
|---|---|
| `UPGRADE_CAP` | `0xb6b4d7e6ce73ca759ce83cfa89bd0ac36fbbea0d72616424386c2ab76e5af9fa` |
| `ADMIN_CAP` | `0x70764e2650a0e9c25ac3b4d0f8ea69d432e69e3b955040b62e9ae32353d23208` |
| `CLT_REWARD_CAP` | `0xfc18bdc85d6807aaadc1a48e62ca849beeaa7b1c868fd7734d5143b73c5fef25` |
| `SUI_REWARD_CAP` | `0x3b3da895eb6b36462964d0c26100f9cd6daecf08ea5b5583a2ebbef5fa7bd228` |
| `TREASURY` | `0xa29ad8ae9f0dfc6fd375a15a87096cf2b9ff93a78a0d4d74edada3cac9ce12cd` |
| `CURRENCY` | `0x6de121eb77413f9c0678188d92c52d477369ca49c4f8bd8b065dfba92400a74b` |
| `TOKEN_POLICY` | `0xb1b2302a79ed9d358bbf7dac1c85dca69bbb40d48f9ae3d7d641508a57fd3c1e` |
| `PLATFORM_CONFIG` | `0x4c92788fe383cd79ab1e3b4c0d396d1b29d92889440c72bc686958badc26b2be` |
| `REWARD_CONFIG` | `0xa1ec797def1dadb139caa9d637fff9b8e01aa0ab0f2fe326da7fa050f9c7555b` |
| `REWARD_REGISTRY` | `0xb466e4cbb6b64586b2c7d6c212c7aacf48709543b4fe2c11c93f50fe27750190` |
| `PRODUCT_CATALOG` | `0xb62aea1d7d5001dee2ff003e723c75adb179333fcd5ee34f849da175fc027d28` |
| `SUPPLY_STATS` | `0x0c93b5da3ee14aa775d3b8b95313e0fd31ed63acc69836db7c25f9b7688b8f92` |
| `SUI_REWARD_CONFIG` | `0x1f3d257b2522946ff258eff65a0f34419b973fcea1a7287642240a9d8325cb1b` |
| `SUI_REWARD_VAULT` | `0xa8947f93e411e989a1482266e11b29afb414d17d07b8ae21397dc0788a7f459d` |

These are recorded configuration values, not a live-state attestation.

There is no localnet deployment manifest or local bootstrap script. Local testing currently uses Move `test_scenario`; Testnet integration uses the recorded IDs and the CLI runbook. Phase 1 must treat IDs as environment configuration and must verify the package source, chain ID, object existence, live owners, pause state, maxima, catalog contents, replay counts, token-policy state, and vault balance before sending transactions.

## 3. Architectural Constraints

The following constraints are non-negotiable:

1. Gameplay simulation and scoring remain off-chain.
2. XP remains backend state and is never minted on Sui.
3. Soft Currency remains backend state and is never represented by `GAME_CREDIT`.
4. CLT means the existing `Token<GAME_CREDIT>`, in integer base units with two decimals.
5. CLT can be rewarded and spent only through the existing policy-controlled closed loop.
6. SUI rewards come only from `SuiRewardVault` SUI that was explicitly deposited beforehand.
7. No CLT amount, balance, purchase, burn, or score creates a right to SUI.
8. No CLT-to-SUI conversion, exchange rate, refund in SUI, swap, redemption, or liquidity path may be added.
9. The browser is untrusted for economic outcomes. It reports gameplay evidence, never reward amounts or fulfillment.
10. Backend services are authoritative for validation, XP, Soft Currency, eligibility, and purchase fulfillment; Sui is authoritative for CLT/SUI settlement, catalog enforcement, replay backstops, and on-chain pauses.
11. A client transaction callback is not settlement evidence. Successful effects plus the expected indexed event are required.
12. Cross-system work uses state machines, unique constraints, an outbox, and reconciliation. There is no false claim of atomicity across a database and Sui.
13. Existing capabilities remain in their current custody during Phase 0. Phase 1 authority movement is an explicit operator action, not application startup behavior.

### 3.1 Trust and source-of-truth boundaries

| Data/decision | Client may report/request | Backend authority | On-chain authority |
|---|---|---|---|
| Fruit positions, merges, local score | Yes, as untrusted gameplay evidence | Validates/recomputes or rejects | None |
| Session identity/status | References only | Creates session ID and owns canonical status/timestamps | None |
| Player identity | Presents auth/wallet proof | Owns account and verified wallet binding | Transaction sender proves wallet control for purchase |
| XP amount | Never | Computes and stores | None |
| Soft Currency amount | Never | Computes and stores | None |
| CLT eligibility/amount | Never | Computes under a versioned rule and submits through CLT service | Enforces cap possession, positive amount, maximum, pause, replay, mint, and recipient delivery |
| Product price/status/limits | Displays queried data only | Caches/indexes; cannot override | `ProductCatalog` is final for purchase acceptance |
| Purchase fulfillment | Never | Applies an entitlement once after confirmed event | Proves exact payment and emits `PurchaseCompleted` |
| SUI eligibility/amount | Never | Computes/approves and submits through isolated SUI service | Enforces cap possession, prefunding, positive amount, maximum, pause, replay, and payout |
| Pause state | Displays queried state | Observes and stops submissions | Existing shared configs are final for protected on-chain flows |

## 4. Suika Game Scope

Phase 1 should implement only the following gameplay loop:

1. The player starts a backend-issued game session.
2. The browser drops fruit into a container.
3. Two equal fruit tiers merge into the next tier and increase local score.
4. The game ends when the container’s loss condition is sustained.
5. The browser submits the finish summary and compact event log to the backend.
6. The backend validates the session, records a canonical score, and applies the rules in this document.

The browser may use ordinary client-side physics. It does not need deterministic on-chain execution. For the architecture test, a compact ordered merge log and basic plausibility checks are sufficient; production-grade anti-cheat is outside Phase 1.

Products are backend inventory entitlements. A confirmed purchase grants one use. The Game API authorizes consumption, and the browser applies the corresponding effect locally. Product pricing, status, and wallet limits remain on-chain; entitlement inventory and gameplay effects remain off-chain.

An authenticated backend player can play without a connected wallet and still receive XP/Soft Currency. A verified wallet is mandatory before CLT or SUI eligibility can be settled and before an on-chain purchase can be associated with a backend player.

## 5. Gameplay Event Model

### 5.1 Common envelope

Events generated by the browser share:

| Field | Type | Authority/validation |
|---|---|---|
| `schemaVersion` | small integer/string | Client echoes the backend-supported schema; backend rejects unsupported versions. |
| `sessionId` | opaque string | Generated by backend; client may only echo it. |
| `sequence` | non-negative integer | Client increments from zero; backend requires strict ordering and no duplicates within the submitted log. |
| `clientOccurredAtMs` | integer | Client telemetry only; never used alone for rewards or limits. |

The client should batch the compact log at game finish instead of making a network request for every physics event. The backend may accept periodic checkpoints for recovery, but they are not needed for the first architecture test.

### 5.2 Minimal events

| Event | Required event-specific fields | Producer | Backend need | Economy effect | Persistence |
|---|---|---|---|---|---|
| `GameStarted` | `clientStartedAtMs` | Browser after receiving a session | Yes; opens only the backend-created session and checks it is not already started/finished | None directly | Persist canonical start transition; retain submitted event during pilot |
| `FruitMerged` | `sourceTier`, `resultTier`, `scoreDelta`, `scoreAfter` | Browser gameplay engine | Yes, in the finish batch, for ordering and score plausibility | Gameplay score only; never an award by itself | Retain compact log for rewarded/flagged pilot sessions and according to a short retention policy |
| `ScoreChanged` | `reason`, `scoreDelta`, `scoreAfter` | Browser’s local UI/game state | No separate backend API event is required; it is derived from accepted `FruitMerged` entries for the initial game | None directly | Do not persist separately unless debugging; avoids a second score source of truth |
| `GameFinished` | `clientFinishedAtMs`, `reportedFinalScore`, `mergeCount`, `maxFruitTier`, `durationMs`, `finishReason`, `eventCount`, `eventLogDigest` | Browser | Yes; triggers validation exactly once | Only after backend validation: XP/Soft Currency and possible reward eligibility | Persist the submitted summary, canonical validation result, canonical score, and rule versions |

`eventLogDigest` detects accidental transport mismatch; because the client creates it, it is not anti-cheat proof. The backend should recompute it over the received canonical encoding.

Allowed `finishReason` values for Phase 1 are `container_overflow`, `player_quit`, and `technical_abort`. Only a normally validated `container_overflow` finish receives the normal completion awards. Operator-approved test fixtures may exercise other paths without creating player rewards.

## 6. Game Session Model

### 6.1 Canonical session record

| Field | Source | Required handling |
|---|---|---|
| `sessionId` | Backend generated (UUID/ULID or equivalent) | Globally unique primary identifier; never client-selected. |
| `playerId` | Backend authentication | Canonical account identity. |
| `walletAddress` | Snapshot from a verified wallet binding, nullable | Client may propose/connect it, but backend stores it only after a signed challenge; immutable for that session once play starts. |
| `serverCreatedAt` | Backend clock | Canonical creation time. |
| `serverStartedAt` | Backend receipt time | Canonical start time; client start time remains telemetry. |
| `serverFinishedAt` | Backend receipt time | Canonical finish receipt time. |
| `clientStartedAt`, `clientFinishedAt` | Client | Plausibility inputs only. |
| `reportedFinalScore` | Client | Untrusted input retained for audit. |
| `validatedFinalScore` | Backend validator | Canonical score used by all economy rules. |
| `status` | Backend state machine | Never client-controlled. |
| `gameConfigVersion` | Backend session creation | Pins fruit tiers, scoring table, physics tolerances, and allowed power-ups. |
| `economyRuleVersion` | Backend validation | Pins XP, Soft Currency, CLT, and SUI eligibility logic. |
| `eventLogDigest`, `eventCount` | Client report, backend recomputed | Stored for integrity/audit, not treated as proof of honesty. |
| `validationCode` | Backend validator | Accepted reason or rejection reason. |

### 6.2 Session status

The minimal backend-owned state machine is:

```text
CREATED -> IN_PROGRESS -> FINISHED_PENDING_VALIDATION -> VALIDATED
                                      |                 -> REJECTED
CREATED/IN_PROGRESS -> ABANDONED
```

Transitions are compare-and-set operations. A duplicate `GameFinished` request returns the existing result and does not create new ledgers or reward jobs. `VALIDATED`, `REJECTED`, and `ABANDONED` are terminal for the first implementation.

### 6.3 Minimum validation

The Phase 1 validator should check:

- authenticated player owns the session;
- session is in the expected state and uses supported config versions;
- event sequences are complete, unique, and ordered;
- each merge combines a valid tier into the valid next tier;
- score deltas match the server scoring table;
- `scoreAfter`, merge count, maximum tier, and final score agree with the submitted log;
- duration and event frequency are within broad plausible bounds;
- claimed power-up use was authorized and atomically consumed from backend inventory;
- the verified wallet binding, when required, existed before settlement.

These checks reduce casual tampering but are not a claim of cheat-proof physics. Suspicious sessions are rejected or held for review; the client cannot override that decision.

## 7. Game-to-Economy Mapping

| Game/business event | Client-reported evidence | Backend-authoritative decision | Final state owner |
|---|---|---|---|
| Fruit merge | `FruitMerged` | Validate merge and recompute score | Off-chain session/game record only |
| Normal game completion | `GameFinished` plus log | Accept/reject, canonicalize score, compute XP | Backend XP ledger |
| Score milestone | Canonical validated score | Compute one Soft Currency band | Backend Soft Currency ledger |
| High-score milestone | Canonical score, valid session, verified wallet | Create at most one fixed CLT reward job | Sui `Token<GAME_CREDIT>` after `CltRewarded` |
| Power-up selection | Product/order request | Create an order intent; never mark it paid from the request | Backend pending order |
| CLT purchase | Player-signed Sui PTB | On-chain catalog/policy validation, then backend event reconciliation | On-chain spent CLT and counters; backend entitlement after fulfillment |
| Special challenge/tournament result | Validated session(s) and challenge rules | Approve winner and fixed SUI amount | Player `Coin<SUI>` after `SuiRewarded` |

Complete logical flows:

```text
XP: Gameplay evidence -> session validation -> XP rule -> idempotent XP ledger

Soft Currency: Gameplay evidence -> session validation -> milestone rule
               -> idempotent Soft Currency ledger

CLT reward: Validated result -> CLT eligibility row/outbox -> isolated CLT Reward Service
            -> reward::reward_player -> final effects + CltRewarded -> confirmed ledger

CLT purchase: Product intent -> player PTB -> ProductCatalog + TokenPolicy validation
              -> PurchaseCompleted -> indexer -> exactly-once entitlement fulfillment

SUI reward: Validated challenge result -> SUI eligibility row/outbox
            -> isolated SUI Reward Service -> sui_reward::reward_player
            -> final effects + SuiRewarded -> confirmed ledger
```

The client never submits fields named or interpreted as `xpAward`, `softCurrencyAward`, `cltAmount`, `suiAmount`, or `fulfilled`. If such fields appear in a request, they are ignored or rejected.

## 8. XP Rules

XP is an off-chain progression value owned by the backend.

For each first-time `VALIDATED` normal completion:

```text
XP = 10 + min(floor(validatedFinalScore / 1,000) * 5, 40)
```

Examples:

| Validated score | XP |
|---:|---:|
| 400 | 10 |
| 1,500 | 15 |
| 3,500 | 25 |
| 9,000 | 50 (cap) |

Rules:

- rejected, abandoned, player-quit, and technical-abort sessions receive zero normal-completion XP;
- the client reports score evidence but never the XP value;
- the backend writes an immutable XP ledger entry keyed by `(playerId, sessionId, economyRuleVersion, "XP")` with a database uniqueness constraint;
- session validation, the XP ledger insert, the player XP aggregate update, and creation of any downstream outbox records occur in one database transaction;
- replaying the finish request returns the existing XP result;
- changing the XP formula changes backend configuration/rule version, not gameplay code or Move code.

## 9. Soft Currency Rules

Soft Currency is a separate off-chain balance. It is neither CLT nor SUI.

Award exactly one band for each first-time validated normal completion:

| Validated score | Soft Currency |
|---:|---:|
| 0–499 | 0 |
| 500–1,499 | 10 |
| 1,500–2,999 | 25 |
| 3,000 or more | 50 |

Rules:

- bands are not cumulative;
- rejected or non-normal sessions receive zero;
- the client cannot state the milestone or amount;
- the backend uses a ledger uniqueness key `(playerId, sessionId, economyRuleVersion, "SOFT")` and updates the aggregate balance in the same database transaction;
- Soft Currency may later buy purely off-chain content, but it must not be accepted by `ProductCatalog` and must not be represented as `GAME_CREDIT`;
- changing bands is a versioned backend configuration change.

## 10. CLT Reward Rules

### 10.1 Initial test rule

A session is eligible for one CLT reward when all conditions hold:

- the session is a first-time `VALIDATED` normal completion;
- `validatedFinalScore >= 3,000`;
- the player has a verified wallet snapshotted on the session;
- no CLT eligibility row already exists for the session and rule version;
- backend fraud/rate checks have not placed the player or session on hold.

The fixed test reward is **500 CLT base units**, equal to **5.00 M**. This is intentionally far below the contract’s initial maximum of 100,000 base units (1,000.00 M). The backend must still read/index the live `RewardConfig`; a source-code initial value is not an operational guarantee.

The backend owns the threshold and amount. The contract does not know a score or session; it enforces authority, amount bounds, pauses, replay, minting, and delivery.

### 10.2 On-chain call

The isolated CLT Reward Service calls:

`reward::reward_player(&mut Treasury, &PlatformConfig, &RewardConfig, &mut RewardRegistry, &RewardCap, recipient, amount, reward_id, ctx)`

Existing on-chain checks require:

- platform not globally paused;
- CLT rewards not paused;
- amount greater than zero;
- amount no greater than `RewardConfig.max_reward_per_transaction`;
- reward ID exactly 32 bytes and not already present in `RewardRegistry.processed`;
- possession of both the mutable `Treasury` and `RewardCap` input.

Success mints the exact amount, delivers a player-owned `Token<GAME_CREDIT>`, registers the ID, and emits `CltRewarded` in one Sui transaction.

### 10.3 Deterministic CLT reward ID

The backend creates a canonical byte encoding and computes:

```text
rewardId = SHA-256(
  "game_economy/clt_reward/v1" ||
  originalPackageId ||
  sessionId ||
  playerId ||
  walletAddress ||
  amountBaseUnits ||
  economyRuleVersion
)
```

The implementation must use length-prefixed/fixed-width fields, not ambiguous string concatenation. SHA-256 produces the contract-required 32 bytes. Including the original package ID and a domain tag prevents accidental reuse across publications and reward domains. A database unique constraint on `(sessionId, economyRuleVersion)` prevents the backend from issuing a second CLT reward with a different ID for the same decision.

### 10.4 Delivery state machine

```text
ELIGIBLE -> QUEUED -> SUBMITTING -> CONFIRMED
                         |-> RETRYABLE_UNKNOWN
                         |-> REJECTED_CONFIG_OR_PAUSE
                         |-> FAILED_PERMANENT
```

`CONFIRMED` requires successful transaction effects and a matching `CltRewarded` event with the expected recipient, amount, and ID. On an ambiguous RPC response, the service/indexer queries by transaction digest and reconciles the deterministic reward ID before retrying. It must not generate a replacement ID merely because the submit response was lost.

## 11. Product Catalog Test Products

`ProductCatalog` accepts only `u64` product IDs and stores price, active status, global sales limit, sold count, and per-wallet purchase limit. It does not store a name, description, or gameplay effect. The following mapping therefore lives in versioned backend/client release configuration while the numeric ID, price, status, and limits are created in the existing on-chain catalog.

| Product ID | Name | Gameplay effect | Test price | Initial on-chain limits | Responsibility |
|---:|---|---|---:|---|---|
| `1001` | Remove Smallest Fruit | Remove the lowest-tier fruit currently in the container | 100 base units (1.00 M) | global `0`, per-wallet `0` (unlimited) | On-chain: exact payment/config/counters. Off-chain: grant one entitlement and apply/validate use. |
| `1002` | Shake Container | Apply one bounded impulse to all current fruit | 150 base units (1.50 M) | global `0`, per-wallet `0` | Same separation. |
| `1003` | Continue After Game Over | Resume once after an overflow, with a safe fruit removal | 250 base units (2.50 M) | global `100`, per-wallet `2` | Intentionally exercises both limits; off-chain fulfillment grants one consumable use. |
| `1004` | Next-Fruit Reroll | Replace the next queued fruit once | 50 base units (0.50 M) | global `0`, per-wallet `0` | Same separation. |

Zero means unlimited in the actual contract. All catalog counts are historical and never reset. The limit on product `1003` is therefore a Testnet pilot limit, not a daily/seasonal limit. Phase 1 must not label it “per day” or “per season.”

Product creation is an operator setup action using `product_catalog::create_product`; application startup must not recreate products. Numeric IDs must be stable once published. Renaming a product off-chain must not silently change its effect semantics; effect changes require a new versioned product mapping and, when materially different, a new numeric product ID.

## 12. CLT Purchase Flow

### 12.1 Order creation

1. The authenticated player selects a product.
2. The Game API resolves the verified wallet and creates a backend purchase intent in `INTENT_CREATED` state.
3. The backend uses a 128-bit-or-greater random order nonce and canonical encoding to compute a 32-byte ID, for example:

   ```text
   orderId = SHA-256(
     "game_economy/purchase/v1" || originalPackageId ||
     backendOrderUuid || walletAddress || productId || randomNonce
   )
   ```

4. A database uniqueness constraint makes `orderId` globally unique. The backend stores the intended player, wallet, product, and current indexed price as expectations, not as authority over the contract.
5. The client reads the live/indexed catalog and constructs the purchase PTB.

The order ID must be unpredictable until use. The contract checks only 32-byte length and global uniqueness; backend records bind it to a player and expected purchase.

### 12.2 Player PTB and contract validation

The player signs the transaction. If their token is larger than the product price, the PTB first calls framework `0x2::token::split<GAME_CREDIT>` and passes the split payment to:

`purchase::purchase_catalog_product(&PlatformConfig, &mut ProductCatalog, &mut TokenPolicy<GAME_CREDIT>, payment, product_id, order_id, ctx)`

The contract checks:

- global platform pause is off;
- CLT spending pause is off;
- order ID is exactly 32 bytes;
- product exists and is active;
- global and per-wallet limits are available;
- order ID is not already processed;
- payment is non-zero and exactly equals the current catalog price;
- the token spend request sender equals `ctx.sender()`;
- the package-private `GamePurchaseRule` satisfies the official policy.

There is no quantity parameter; one call buys one product unit. A stale cached price causes the transaction to abort without purchase state changes. The UI then refreshes the catalog and asks the player to approve a new transaction; it never silently changes the amount in an already signed transaction.

### 12.3 Event-driven fulfillment

On success, the same Sui transaction:

- moves the exact CLT amount into `TokenPolicy` spent balance;
- increments product sold count;
- increments the `(productId, buyerWallet)` count;
- records the order ID;
- emits `PurchaseCompleted { buyer, product_id, amount, order_id }`.

The backend does not fulfill from a client callback. The Event Indexer verifies successful effects and the event, deduplicates it, matches `orderId`, `buyer`, `productId`, and `amount` to the intent, and passes it to the Purchase Fulfillment Service.

Fulfillment runs in one database transaction:

- insert a unique fulfillment ledger row keyed by `orderId`;
- increment the appropriate backend consumable inventory by one;
- mark the order `FULFILLED`;
- enqueue any player notification through the outbox.

If the event is valid but no intent exists, the indexer stores `UNMATCHED_CONFIRMED_PURCHASE` and alerts/retries wallet-to-account resolution. It does not discard the event or grant an arbitrary account. If fulfillment fails after payment, the order remains `PAID_PENDING_FULFILLMENT` and retries; on-chain payment is not rolled back.

### 12.4 Purchase states

```text
INTENT_CREATED -> WALLET_SUBMITTED -> PAID_CONFIRMED -> FULFILLED
       |                  |                  |-> PAID_PENDING_FULFILLMENT
       |                  |-> CHAIN_REJECTED
       |-> EXPIRED_UNUSED
```

An expired unused ID may remain unused forever. A confirmed ID is never reused, even if the player later consumes the entitlement.

## 13. SUI Reward Rules

### 13.1 Initial test challenge

SUI is reserved for an explicitly configured special challenge/tournament, not an ordinary score threshold. The first architecture test uses:

- one operator-opened challenge window;
- validated sessions only;
- one winning entry after the window closes;
- a verified winner wallet;
- fixed reward **10,000,000 MIST (0.01 SUI)**;
- one reward per challenge result.

The Challenge Service/validator selects the winner from backend-canonical scores and records an immutable result. The browser cannot claim placement or amount. The vault must be funded before payout. The fixed test amount is below the contract’s initial maximum of 100 SUI, but the service must use the live indexed `SuiRewardConfig` and vault balance.

### 13.2 Deterministic SUI reward ID

```text
rewardId = SHA-256(
  "game_economy/sui_reward/v1" ||
  originalPackageId ||
  challengeId ||
  challengeResultId ||
  sessionId ||
  walletAddress ||
  amountMist ||
  economyRuleVersion
)
```

Use canonical length-prefixed/fixed-width encoding. The database has unique constraints on `challengeResultId` and the resulting 32-byte ID. The separate domain tag is required even though CLT, purchase, and SUI replay state are stored in independent on-chain namespaces.

### 13.3 Funding and payout flow

1. An operator/funder deposits a non-zero `Coin<SUI>` with `sui_reward::deposit_sui`. Funding is permissionless and produces no authority or claim.
2. The Event Indexer confirms `SuiVaultFunded` and updates the observed balance projection.
3. Backend validation finalizes a unique challenge result and writes a SUI outbox item.
4. The isolated SUI Reward Service, holding only `SuiRewardCap`, calls:

   `sui_reward::reward_player(&PlatformConfig, &SuiRewardConfig, &mut SuiRewardVault, &SuiRewardCap, recipient, amount, reward_id, ctx)`

5. The contract checks global/SUI pauses, positive amount, live maximum, 32-byte replay ID, uniqueness, and sufficient vault balance.
6. Success atomically records the ID, splits the exact amount from the vault, transfers `Coin<SUI>` to the player, and emits `SuiRewarded`.
7. Final effects plus the matching event change the backend job to `CONFIRMED`.

This flow neither reads nor modifies CLT supply, tokens, spent balance, catalog state, or CLT replay state. A CLT balance is never an eligibility input.

## 14. Authority Ownership Model

| Future owner | Objects/keys | Permitted work | Explicitly excluded work |
|---|---|---|---|
| Upgrade operator/security multisig | `UpgradeCap` | Reviewed compatible upgrades only | Routine admin, rewards, fulfillment, gameplay |
| Operator/admin custody | `AdminCap` | Catalog configuration; global/domain pause; CLT/SUI maximum changes; controlled admin rotation | CLT mint/flush, SUI payout, player purchase signing |
| CLT Reward Service signer | `RewardCap` and `Treasury` together | `reward::reward_player`, `supply::flush_spent_tokens`, paired rotation | SUI payout, product/admin changes, backend XP/Soft Currency mutation outside its job input |
| SUI Reward Service signer | `SuiRewardCap` | `sui_reward::reward_player`, authority rotation | CLT mint/flush, product/admin changes, vault arbitrary withdrawal |
| Funder/operator wallet | Ordinary `Coin<SUI>` | `sui_reward::deposit_sui` | Receives no payout authority or refund claim |
| Player wallet | Gas and `Token<GAME_CREDIT>` | Signed purchase PTBs | Reward mint, SUI payout, config/admin mutation |

Isolation is necessary because compromise impact differs:

- `UpgradeCap` can change code and is the root risk, so it is kept away from hot services.
- `AdminCap` can stop or reconfigure flows but cannot directly move value.
- `RewardCap` without `Treasury`, or `Treasury` without `RewardCap`, cannot use the public CLT reward/flush endpoints; operationally they stay together because both are required for every call and rotate as one unit.
- `SuiRewardCap` can release real prefunded SUI and therefore must not share a signer or process with the CLT service.
- no general “backend wallet” may hold all capabilities.

Phase 0 does not transfer any authority. Before Phase 1, operators must query live owners and decide the reviewed Testnet custody addresses. Rotation functions are `platform::transfer_administration`, `reward::transfer_reward_authority`, and `sui_reward::transfer_sui_reward_authority`. All three are currently single-transaction transfers and require careful recipient verification.

## 15. Backend Components

These are logical boundaries; they do not all need separate deployables. Signer isolation must remain a process/key boundary even if ordinary API and ledger logic begin in one service.

| Component | Responsibility |
|---|---|
| Game API and Session Service | Authenticate players, verify wallet bindings, issue sessions/config versions, ingest batched gameplay events, own session state transitions, and expose validated results. |
| Session Validator | Recompute scores from compact logs, validate power-up use and plausibility, and return an accepted score or rejection code. It has no blockchain key. |
| Player Economy Service | Own XP, Soft Currency, backend inventory, immutable ledgers, aggregates, and database idempotency. It creates CLT/SUI eligibility outbox rows but cannot sign those transactions. |
| CLT Reward Service | Consume approved CLT outbox rows, construct/submit `reward::reward_player`, reconcile events, and optionally schedule authorized spent-token flushes. It is the only application service with `RewardCap` plus `Treasury` access. |
| SUI Reward Service | Consume approved SUI outbox rows, check indexed live config/balance, construct/submit `sui_reward::reward_player`, and reconcile events. It is the only service with `SuiRewardCap`. |
| Purchase Fulfillment Service | Consume confirmed `PurchaseCompleted` records and grant one backend entitlement exactly once. It has no admin or reward capability. |
| Transaction Orchestrator library/adapter | Shared non-custodial code for PTB construction, gas, submission, digest tracking, effects validation, and ambiguous-response recovery. It must not combine signer secrets or authorize economic decisions. |
| Event Indexer and Reconciler | Follow the recorded package’s final events/checkpoints, maintain catalog/pause/max/vault projections, deduplicate chain events, drive reward confirmation and purchase fulfillment, detect gaps, and backfill from a durable cursor. |
| Operator tooling | Read-only monitoring plus separately authorized admin actions. It is not exposed through player APIs. |

The minimal persistent backend data is: players/wallet bindings, sessions and compact logs, XP/Soft ledgers and balances, inventory ledger, purchase intents/fulfillments, CLT/SUI eligibility and transaction jobs, chain event inbox/cursor, and an outbox.

## 16. Event and Fulfillment Flow

### 16.1 Gameplay-to-ledger flow

1. `GameFinished` ingestion uses a request idempotency key and locks/compares session status.
2. The validator produces a canonical result.
3. One database transaction writes terminal session state, XP and Soft Currency ledgers, inventory consumption, and any CLT eligibility outbox item.
4. API response is generated from committed state. Retrying returns the same result.

### 16.2 Chain transaction flow

1. A worker locks one transaction job and records the deterministic ID and expected call inputs before submission.
2. It builds against environment-configured package/shared-object IDs and the signer’s currently owned capability objects.
3. It submits and stores the digest when known.
4. It validates successful effects and expected event fields. RPC success without the event is held for reconciliation.
5. The chain event inbox deduplicates on `(chainId, transactionDigest, eventSequence)` and also enforces uniqueness of the economic `reward_id`/`order_id` within its domain.
6. A database transaction applies the projection/fulfillment and advances the event cursor/outbox.
7. A periodic reconciler compares pending jobs with indexed events and direct transaction queries.

### 16.3 Event routing

| Event | Backend action |
|---|---|
| `CltRewarded` | Match job by `reward_id`; verify recipient/amount; mark CLT delivery confirmed. |
| `PurchaseCompleted` | Match intent; verify buyer/product/amount; enqueue exactly-once entitlement fulfillment. |
| `SuiRewarded` | Match job by `reward_id`; verify recipient/amount; mark SUI delivery confirmed. |
| Catalog events | Update product cache/projection and invalidate stale UI/API values. |
| Pause/maximum events | Update operational projection; stop affected job submissions until state is reconciled. |
| Authority transfer events | Alert and update expected-custody monitoring only after direct owner verification. |
| `SuiVaultFunded` | Update observed funding history/balance projection; direct object state remains authoritative. |
| `CltSpentFlushed` | Update burn/supply audit projection. |

Events are synchronization records, not a replacement for transaction effects or current object reads. On startup or cursor loss, the indexer backfills events and then reconciles current shared-object state.

## 17. Replay Protection Strategy

| Domain | Primary idempotency | On-chain backstop | Retry rule |
|---|---|---|---|
| Session finish | Unique `sessionId` terminal transition and request key | None | Return stored result; do not rerun ledgers. |
| XP | Unique `(playerId, sessionId, ruleVersion, XP)` ledger | None | Duplicate insert becomes read-existing. |
| Soft Currency | Unique `(playerId, sessionId, ruleVersion, SOFT)` ledger | None | Duplicate insert becomes read-existing. |
| CLT reward | Unique eligibility per session/rule plus deterministic 32-byte ID | `RewardRegistry.processed` | Reconcile same ID; never mint under a new ID because a response is ambiguous. |
| Purchase | Unique backend order and fulfillment rows; high-entropy 32-byte ID | `ProductCatalog.processed_orders` | A confirmed ID is final. An unused rejected intent may create a new order only after proving no successful payment. |
| SUI reward | Unique challenge result plus deterministic 32-byte ID | `SuiRewardVault.processed` | Reconcile same ID; never pay under a replacement ID after ambiguous submission. |
| Chain event processing | Unique chain event key and economic ID | Existing chain state | Reprocessing is a no-op. |

The existing tests prove that identical byte values may independently exist in the CLT reward, purchase order, and SUI reward namespaces. Phase 1 still uses domain-separated hashes to avoid operator and analytics mistakes.

On-chain replay state is package/object scoped. A future new publication must not assume it inherits the v1 tables. Including `originalPackageId` in IDs, retaining backend ledgers, and planning an explicit migration/reconciliation policy are mandatory for any later publication or registry replacement.

## 18. Failure and Security Scenarios

The following matrix is the minimum Phase 1 architecture test suite. “Existing evidence” identifies relevant Move unit coverage; Phase 1 must still exercise the complete browser/backend/Testnet path where specified.

### 18.1 Happy paths

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| H1 | Finish a valid normal game once | Session reaches `VALIDATED`; canonical score matches log; duplicate finish returns the same result | New backend integration test |
| H2 | Validated score 1,500 | Exactly 15 XP is added once; no client-supplied amount is accepted | New backend test |
| H3 | Validated score 1,500 | Exactly 25 Soft Currency is added once and remains separate from CLT | New backend test |
| H4 | Validated score at least 3,000 with verified wallet | One 500-base-unit CLT job; successful `CltRewarded`; player receives exact `Token<GAME_CREDIT>`; backend confirms once | `clt_reward_tests::authorized_reward_mints_exact_clt_records_replay_and_emits_event` |
| H5 | Buy active product with exact current price | Exact CLT enters policy spent balance; catalog/order counts increment once; one `PurchaseCompleted`; backend grants one entitlement | `purchase_tests::exact_price_purchase_consumes_payment_updates_counts_and_emits_event` |
| H6 | Win configured challenge with funded vault | Exactly 10,000,000 MIST leaves vault and reaches wallet; one `SuiRewarded`; CLT state unchanged | `sui_reward_tests::authorized_reward_pays_exact_sui_updates_vault_and_emits_event`, `sui_reward_tests::sui_reward_does_not_change_clt_supply_or_spent_balance` |

### 18.2 Replay and idempotency

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| R1 | Submit the same CLT reward ID twice, including once with another recipient/amount | Second call aborts `ERewardAlreadyProcessed`; no supply/player/replay delta; backend keeps original confirmed job | `clt_reward_tests::duplicate_reward_id_is_rejected` |
| R2 | Submit the same purchase order ID twice | Second call aborts `EPurchaseAlreadyProcessed`; payment/counters/spent balance unchanged by failure; fulfillment ledger remains one row | `purchase_tests::reused_order_id_is_rejected` |
| R3 | Submit the same SUI reward ID twice | Second call aborts `ERewardAlreadyProcessed`; vault/player/replay unchanged by failure | `sui_reward_tests::duplicate_reward_id_is_rejected` |
| R4 | Deliver the same chain event to the indexer twice | Event inbox, confirmation, inventory, and notifications change once | New backend/indexer test |
| R5 | Send `GameFinished` twice | XP, Soft Currency, inventory consumption, and CLT eligibility are created once | New backend test |
| R6 | Use identical 32-byte values in CLT reward, purchase, and SUI domains | Each succeeds once in its independent namespace; backend domain tags remain distinct | `security_tests::replay_namespaces_are_independent_across_clt_purchase_and_sui` |

### 18.3 Pause behavior

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| P1 | Admin activates `platform::pause_platform` | New CLT reward, purchase, and SUI payout abort with domain `EPlatformPaused`; failed IDs remain unused. SUI deposits and admin operations remain possible. Backend XP/Soft Currency are not on-chain-gated and may continue under product policy. | CLT, purchase, and SUI global-pause tests plus runbook section 20 |
| P2 | Admin activates `platform::pause_clt_spending` | Purchases abort `ECltSpendingPaused`; CLT rewards and SUI payouts remain available if otherwise valid | `purchase_tests::clt_spending_pause_blocks_purchase` |
| P3 | Admin activates `reward::pause_clt_rewards` | CLT rewards abort `ERewardsPaused`; purchases and SUI payouts remain available | `clt_reward_tests::clt_reward_pause_blocks_reward` |
| P4 | Admin activates `sui_reward::pause_sui_rewards` | SUI payouts abort `ERewardsPaused`; deposits, CLT rewards, and purchases remain available | `sui_reward_tests::dedicated_pause_blocks_sui_reward` |
| P5 | Unpause each domain and retry the previously blocked unique operation | Operation succeeds with the same unused ID when all other conditions hold | Existing pause/unpause event tests; Phase 1 end-to-end retry required |
| P6 | Repeat pause or unpause in the same state | Matching already-paused/not-paused abort; backend projection remains aligned | `security_tests::repeated_global_pause_is_rejected` and domain tests |

### 18.4 Product configuration

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| C1 | Disable a product, then attempt purchase | Purchase aborts `EProductInactive`; no payment/counter/order change; UI/indexer reflects disabled state | `purchase_tests::disabled_product_is_rejected` |
| C2 | Change product price from 100 to 150; submit stale 100, then exact 150 | Stale payment aborts `EInvalidPaymentAmount`; refreshed exact payment succeeds; gameplay code is unchanged | Price update and underpayment tests; new combined integration test |
| C3 | Reach non-zero per-wallet limit and buy again from the same wallet | Purchase aborts `EPlayerPurchaseLimitReached`; another wallet is independently counted | `product_tests::per_player_limit_cannot_be_bypassed`, `different_players_have_independent_purchase_counts` |
| C4 | Reach global sold limit and buy again | Purchase aborts `EGlobalSalesLimitReached` | `product_tests::global_sales_limit_cannot_be_bypassed` |
| C5 | Attempt zero price, duplicate product ID, or finite global limit below sold count | Admin transaction aborts; existing product/history remains | Existing product negative tests |

### 18.5 Authority isolation

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| A1 | Admin signer attempts CLT mint without `RewardCap` and `Treasury` | Transaction cannot be constructed/executed with those owned inputs; no mint | `clt_reward_tests::admin_cap_does_not_grant_clt_treasury_authority` |
| A2 | CLT service attempts SUI payout | It lacks `SuiRewardCap`; `RewardCap` is a different Move type and cannot substitute | `sui_reward_tests::reward_capabilities_are_independent` |
| A3 | SUI service attempts CLT mint/flush | It lacks `RewardCap` and `Treasury`; `SuiRewardCap` cannot substitute | Same capability-separation tests |
| A4 | Player attempts pause, product update, reward, flush, or payout using recorded cap IDs | Sui rejects non-owned object inputs or Move type requirements; no state/event change | `security_tests::capability_and_framework_authority_ownership_matches_model` and runbook authorization tests |
| A5 | Rotate CLT authority | `RewardCap` and `Treasury` end under the same new owner and one transfer event is indexed | `clt_reward_tests::authority_handoff_moves_cap_and_treasury_together` |
| A6 | Rotate admin or SUI authority | Only the intended cap moves; unrelated roles remain isolated; event and direct owner query agree | `security_tests::admin_rotation_moves_only_admin_authority`, SUI rotation test |
| A7 | Monitor `UpgradeCap` owner | Any unexpected owner/version change is a critical alert because application caps cannot constrain an upgrade | New operational test |

### 18.6 Vault, amount, policy, and trust failures

| ID | Scenario and action | Expected result | Existing evidence |
|---|---|---|---|
| V1 | SUI reward exceeds vault balance but is below maximum | Abort `EInsufficientVaultBalance`; no payout/replay/event; backend marks funding-required, not confirmed | `sui_reward_tests::insufficient_vault_balance_is_rejected_before_replay_registration` |
| V2 | SUI reward exceeds configured maximum | Abort `ERewardTooLarge`; vault/replay unchanged | Existing SUI maximum tests |
| V3 | CLT reward exceeds configured maximum | Abort `ERewardTooLarge`; supply/replay/player unchanged | Existing CLT maximum tests |
| V4 | Zero reward/deposit or malformed reward/order ID | Matching validation abort; no state consumed | Existing CLT, purchase, SUI boundary tests |
| V5 | Underpay, overpay, or use zero CLT payment | Purchase aborts; original PTB effects roll back; no fulfillment | Existing purchase payment tests |
| V6 | Attempt raw token spend approval or a forged rule type | Official policy rejects it with `token::ENotApproved` | `purchase_tests::raw_spend_request_cannot_bypass_purchase_rule`, `forged_rule_type_cannot_bypass_purchase_rule` |
| V7 | Client sends forged final score and requested reward fields | Validator rejects/canonicalizes score; requested economic fields are ignored; no unauthorized ledger/job | New backend trust-boundary test |
| V8 | Valid `PurchaseCompleted` arrives without a backend intent | Preserve as unmatched, resolve buyer wallet, and alert; never grant an arbitrary account or discard paid state | New indexer/fulfillment recovery test |
| V9 | RPC returns timeout after submission | Query digest/events/ID before retry; never issue a second ID | New transaction-orchestrator fault test |

## 19. Atomicity Tests

### 19.1 Sui transaction atomicity

| ID | Test | Required invariant |
|---|---|---|
| T1 | Failed purchase for unknown/disabled product, wrong amount, reached limit, duplicate order, pause, or policy failure | Player token, `TokenPolicy.spent_balance`, product `sold_count`, per-wallet count, processed-order count, and events are unchanged by the failed transaction. |
| T2 | Successful purchase | Payment consumption, policy spent balance, all catalog counters, order replay, and `PurchaseCompleted` appear together or none appear. |
| T3 | CLT mint fails after replay insertion is attempted, such as induced supply overflow in a controlled test | `RewardRegistry` entry, total supply, player token, Treasury version/economic state, and event all roll back. `security_tests::clt_supply_overflow_aborts_instead_of_wrapping` provides the failure path; Phase 1/local integration should compare state before/after. |
| T4 | CLT reward fails for pause, maximum, malformed/duplicate ID, or zero amount | No replay entry, mint, delivery, or event remains. |
| T5 | SUI payout fails for insufficient balance, pause, maximum, malformed/duplicate ID, or zero amount | Vault balance, replay set, player SUI objects, and events are unchanged. |
| T6 | Flush fails for empty spent balance or burn-accounting overflow | Policy balance, total supply, cumulative burn, and event remain unchanged. |
| T7 | Successful flush | Entire spent balance becomes zero, supply falls by the same amount, cumulative burned rises by the same amount, and one `CltSpentFlushed` reports the values. |

Dry runs are useful for input validation but cannot alone prove rollback of an executed abort because they never commit. Testnet/local integration should snapshot objects, submit a transaction expected to abort, obtain failed effects, and compare current object state. Sui atomic execution means replay writes performed before a later abort also roll back.

### 19.2 Backend-local atomicity

| ID | Test | Required invariant |
|---|---|---|
| T8 | Database error while finishing a session | Terminal session state, XP/Soft ledger entries, aggregates, inventory consumption, and outbox records all commit together or all roll back. |
| T9 | Fulfillment worker crashes after reading `PurchaseCompleted` | Unique `orderId` transaction causes either one complete entitlement/ledger update or none; retry completes it once. |
| T10 | Indexer crashes after applying event but before cursor acknowledgement | Replayed event is a no-op and cursor advances safely. |
| T11 | Reward service crashes around submission | Persistent job/digest/ID plus reconciliation prevents a second economic delivery. |

### 19.3 Cross-system consistency

There is intentionally no distributed transaction between the backend database and Sui.

- A validated session may have XP/Soft Currency committed while its CLT reward is `QUEUED` or temporarily blocked by pause. This is consistent, not a partial database transaction.
- A confirmed purchase may remain `PAID_PENDING_FULFILLMENT` while backend entitlement retry runs. The payment remains valid and must eventually be fulfilled or operationally resolved.
- A CLT/SUI job is not `CONFIRMED` until chain evidence is reconciled.
- Dashboards and player APIs must expose pending states instead of claiming rollback or success prematurely.

## 20. Scalability / Contention Risks

No redesign is proposed in Phase 0. The following actual objects should be benchmarked before mainnet/load assumptions.

| Mutated object/input | Flows | Why transactions may serialize or conflict | Benchmark target |
|---|---|---|---|
| `RewardRegistry` (`&mut`) | Every CLT reward | One shared mutable root and one global replay table order all CLT reward registration | Concurrent CLT rewards; throughput, P50/P95/P99 finality, shared-object congestion, gas as replay table grows |
| `Treasury` (`&mut`, address-owned) | Every CLT reward and every flush | All CLT mints/flushes use one owned mutable object; flush also competes with rewards | Worker concurrency, owned-object version/equivocation handling, reward-vs-flush interference |
| `RewardCap` (owned input) | Every CLT reward and flush | A single address-owned capability is reused, adding client-side sequencing constraints even though borrowed immutably | Safe in-flight count and signer queue behavior |
| `ProductCatalog` (`&mut`) | Every purchase and all product administration | One shared mutable object covers all products, player counts, sold counts, and order replay; different products still touch the same root | Purchases across same/different products and wallets; admin-update interference; table-growth gas/query cost |
| `TokenPolicy<GAME_CREDIT>` (`&mut`) | Every purchase and flush | Official global spent balance changes every time; purchases serialize with each other and with flush | Purchase throughput; purchase-vs-flush latency; appropriate flush cadence |
| `SuiRewardVault` (`&mut`) | Every deposit and payout | Balance and replay table share one mutable root, so deposits and unrelated payouts contend | Concurrent deposits/payouts; vault-balance and replay-table growth; event-index lag |
| `SuiRewardCap` (owned input) | Every SUI payout | One reused owned capability constrains the signer queue | Safe worker concurrency and lock/retry behavior |
| `SupplyStats` (`&mut`) | Every flush | Global cumulative counter; low frequency but paired with policy/Treasury | Flush gas/finality and failure rollback |
| `PlatformConfig` (`&mut` only for admin; `&` on protected flows) | Pause changes vs all protected calls | Normal immutable reads can be concurrent, but a pause write must order against affected traffic | Pause propagation time under load and operations admitted before/after checkpoint |
| `RewardConfig`, `SuiRewardConfig` (`&mut` only for admin; `&` on rewards) | Maximum/pause changes vs rewards | Low-volume writes order against reward reads | Configuration propagation and stale-job rejection behavior |

Replay and count tables also grow indefinitely. Although individual `Table` lookups are dynamic-field operations rather than linear scans, storage, gas, RPC pagination, index size, and backfill time must be measured at representative sizes.

Minimum later load profiles:

- concurrency 1, 5, 10, 25, and 50 for each economic flow;
- mixed CLT reward plus flush;
- mixed purchase plus flush;
- mixed SUI funding plus payout;
- purchases of one product versus many products;
- replay tables at approximately 1,000, 100,000, and projected production entries;
- P50/P95/P99 submit-to-final-effects and effects-to-indexed latency;
- successful throughput, lock/conflict/retry rate, gas, RPC error rate, and backend queue age.

## 21. Adaptability Tests

| Change | Existing control | Test without gameplay-code changes |
|---|---|---|
| Change a product price | `product_catalog::update_product_price` | Index new event/state; stale exact payment fails and refreshed payment succeeds. Game physics/scoring remain unchanged. |
| Disable/re-enable a product | `disable_product`, `enable_product` | UI/API availability changes; disabled purchase fails; existing entitlements remain governed by backend inventory policy. |
| Change global/per-wallet limits | `update_product_limits` | New purchases observe limits without resetting historical counts. |
| Add another configured product | `create_product` | Add a numeric ID and off-chain metadata/effect mapping. A genuinely new effect may require gameplay implementation; a price/status/limit change does not. |
| Change CLT per-call maximum | `reward::update_max_reward_per_transaction` | A reward at the new maximum succeeds; one above it fails. Backend high-score rule remains separately configurable. |
| Pause only CLT rewards | `pause_clt_rewards`, `unpause_clt_rewards` | CLT jobs wait/reject while purchases and SUI rewards continue. |
| Pause only CLT spending | `pause_clt_spending`, `unpause_clt_spending` | Purchases fail while CLT/SUI rewards continue. |
| Change SUI per-call maximum | `sui_reward::update_max_reward_per_transaction` | Challenge payout observes new ceiling without CLT or gameplay changes. |
| Pause only SUI rewards | `pause_sui_rewards`, `unpause_sui_rewards` | SUI payouts stop; SUI deposits and CLT flows remain independent. |
| Pause all on-chain player-facing flows | `pause_platform`, `unpause_platform` | CLT reward/purchase/SUI payout stop. Backend XP/Soft behavior follows an explicit operator policy, not an invented on-chain effect. |
| Rotate admin authority | `platform::transfer_administration` | New verified owner can administer; old owner cannot; event plus direct ownership agree. |
| Rotate CLT authority | `reward::transfer_reward_authority` | `RewardCap` and `Treasury` move together; old service cannot submit. |
| Rotate SUI authority | `sui_reward::transfer_sui_reward_authority` | New isolated service can pay; old service cannot. |
| Change XP, Soft Currency, high-score threshold, or fixed award below live maxima | Versioned backend economy configuration | New sessions pin the new rule version; gameplay continues emitting generic score/finish evidence. No Move change. |

Authority rotation is an operator-run test with explicit approval. Application deployment or autoscaling must never rotate capabilities automatically.

## 22. Potential Smart Contract Gaps

### 22.1 Conclusion

**No smart contract change is necessary before Phase 1.** The existing package provides all required settlement, configuration, pause, replay, capability, event, and atomicity primitives for this architecture test. The gaps below are either intentional trust boundaries, off-chain concerns, operational hardening opportunities, or later scalability questions.

### 22.2 Gap assessment

| Potential gap/problem | Blocks the web game? | Off-chain handling | Smallest possible future contract change | Phase 0 recommendation |
|---|---|---|---|---|
| On-chain rewards do not verify a game session, score, or tournament proof; a cap holder can reward any address within limits | No. The architecture explicitly makes the backend reward authority trusted. | Strict validation, database eligibility uniqueness, signer service isolation, limits, monitoring, and event reconciliation | Add a compatible new attestation-based reward function/type if future trust minimization requires it; this would be a substantive protocol change, not needed now | Keep current contract; test the intended trust boundary |
| Catalog per-player limits are actually lifetime **per wallet**, not per backend account, person, day, or season | No for Phase 1 | Enforce account/season limits in backend; label on-chain limit accurately; use verified wallet binding | Add a season/epoch to the count key or introduce versioned catalogs/products in a new compatible API | Use wallet-level limits only for the pilot; do not promise stronger semantics |
| Catalog and replay tables have no pruning/partitioning and their shared roots are global hotspots | No at pilot volume | Backend unique constraints, queues, metrics, and bounded Testnet load | Later shard/bucket registries/catalogs, use derived objects, or add epoch-specific objects after benchmarks | Benchmark first; do not redesign speculatively |
| Capability rotations are single-step transfers, so a wrong recipient can strand key-only authority | No | Multisig approval, checksum/address allowlists, direct owner verification, dry run, staged runbook, and recovery drills | Add a carefully designed propose/accept or claim handshake via compatible new functions/objects; ownership coordination must be reviewed in Sui’s object model | Do not change for Phase 1; treat rotation as high-risk operator action |
| `PurchaseCompleted` has no backend player/session field and an on-chain purchase may occur without a prior backend intent | No | Bind high-entropy `orderId` to verified wallet/account; preserve unmatched events and resolve by buyer | Add a compatible v2 purchase function/event with an opaque account commitment if gifting/cross-account flows later require it | Existing order ID and buyer are sufficient for the test |
| No on-chain purchase refund/cancel path exists after CLT is spent | No if fulfillment is reliable | Exactly-once entitlement ledger, durable retry, alerting, and manual entitlement repair; disclose finality before signature | Add a narrowly policy-approved refund design only if product requirements demand it; it would expand the closed-loop attack surface | Do not add a refund path for Phase 1 |
| SUI vault has no arbitrary/admin withdrawal, so unused funding can leave only through valid rewards | No; this is a deliberate safety property | Fund only the reviewed test budget and monitor balance | Add a separately capped/paused/emitted emergency withdrawal requiring an appropriate authority | Preserve current one-way funding for the architecture test |
| Production catalog/config getters are not exposed as public Move getters; many source getters are `#[test_only]` | No | Read object contents/dynamic fields through Sui RPC/GraphQL and maintain an event-backed projection | Add public immutable accessors if a future Move package or transaction needs them | Use indexer/RPC; no change needed |
| A backend can accidentally reward one session twice using two different valid reward IDs because on-chain replay knows IDs, not session semantics | No | Unique `(sessionId, ruleVersion)` and challenge-result constraints; deterministic ID generation | Session commitment in a new reward API, if later necessary | Backend idempotency is the correct current layer |
| Global pause does not pause XP, Soft Currency, SUI funding, CLT flush, or administration | No; source and runbook make this intentional | Define operator policy for off-chain ledgers; UI clearly reports which domains are paused | Expand pause checks only if governance requirements change | Preserve current scope and test it explicitly |
| Upgrade authority can supersede all capability separation | No; inherent in an upgradeable package | Isolate `UpgradeCap`, use multisig/cold custody, monitor package version/source, and require reviewed upgrades | Restrict upgrade policy or make package immutable through framework controls | Operational decision outside Phase 0; verify custody before Phase 1 |

### 22.3 Non-contract repository gaps

- `ARCHITECTURE.md` and early `TESTNET_DEPLOYMENT.md` text still say there is no `Published.toml` and describe a first pending publication. `Published.toml`, the ignored deployment record, and git history show that Testnet version 1 was published. This is documentation drift, not a Move gap.
- The recorded Testnet environment contains public object IDs but does not prove current live owners, pause state, catalog contents, replay counts, vault balance, or source match. Phase 1 setup must query and record those values.
- There is no localnet bootstrap/deployment configuration. Move unit tests use `test_scenario`; Phase 1 can begin on the recorded Testnet deployment or later add a separate, explicitly scoped local integration harness.

The documentation drift should be corrected in a later documentation/operations change, but it does not justify modifying the smart contracts or blocking this Phase 0 specification.

## 23. Phase 0 Acceptance Criteria

Phase 0 is accepted when this document is reviewed and the following statements remain true:

- [x] The specification uses the actual modules, types, functions, objects, events, tests, and deployment records.
- [x] Existing Move contracts remain the source of truth and were not rewritten.
- [x] Gameplay simulation remains off-chain.
- [x] XP and Soft Currency are backend-owned, independently ledgered values.
- [x] CLT is the existing closed-loop `Token<GAME_CREDIT>` and is not a freely transferable coin.
- [x] SUI payout is independent and limited to a pre-funded vault.
- [x] No CLT-to-SUI conversion, redemption, exchange rate, swap, or implicit relationship exists.
- [x] Client-reported gameplay evidence is separated from backend-authoritative economic decisions.
- [x] Every application capability plus `Treasury` and `UpgradeCap` is mapped to isolated future custody.
- [x] XP, Soft Currency, CLT reward, purchase, and SUI reward flows are specified end to end.
- [x] Game events, session fields, validation ownership, and persistence are defined without unnecessary gameplay infrastructure.
- [x] Four catalog-compatible test products and exact base-unit prices/limits are defined.
- [x] Deterministic/unique 32-byte IDs match the current contract’s exact length and replay requirements.
- [x] Event indexing and exactly-once fulfillment rely on final chain evidence, not client callbacks.
- [x] Happy path, replay, pause, product, authority, vault, policy, trust, failure, and atomicity scenarios are defined.
- [x] Cross-system pending/reconciliation behavior is defined without claiming database/Sui atomicity.
- [x] Actual shared mutable objects and owned capability bottlenecks are listed for later benchmarking.
- [x] Configuration and authority adaptability tests name the existing functions that enable them.
- [x] Potential gaps include blocking status, off-chain handling, and the smallest possible future change.
- [x] No contract change is recommended before Phase 1.
- [x] The unchanged Move package passes all 89 tests under the recorded Testnet build environment.

Before executing Phase 1 against Testnet, operations must separately verify chain ID, package source/version, every configured object, live capability ownership, live pauses/maxima, catalog state, replay/counter state, policy spent balance, and SUI vault funding. That verification is a Phase 1 setup action and must not be inferred from this static review.
