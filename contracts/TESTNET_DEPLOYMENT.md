# Testnet deployment and end-to-end verification

This runbook is for package `game_economy` and the installed CLI
`sui 1.76.1-433212f8f276`. Commands were checked against that CLI's `--help`.
They intentionally do not publish automatically. Values in angle brackets are
placeholders, never example on-chain IDs.

Amounts for `GAME_CREDIT` are base units: it has two decimals, so `100` means
`1.00 M`. Native SUI amounts are MIST: `1 SUI = 1_000_000_000 MIST`.

## 1. Prerequisites

```bash
cd /home/mert/Software/move/web3-infra
sui --version
jq --version
git status --short --branch
```

Expected Sui version for this reviewed source is
`sui 1.76.1-433212f8f276`. `Move.lock` pins the Testnet Sui framework and
MoveStdlib at revision `d50b78880fdacb1bbde92e6974ed71a7650c1090`.

This is the first canonical Testnet publication: the reviewed repository has
no `Published.toml`, package ID, original package ID, or prior upgrade state.

## 2. Build, lint, and unit tests

```bash
sui move build --build-env testnet --warnings-are-errors
sui move lint --build-env testnet --test --warnings-are-errors
sui move test --build-env testnet --warnings-are-errors
```

The installed CLI delegates `sui move format` to `prettier-move`, which is not
installed in the reviewed environment. Do not install or upgrade tooling only
for publication; the checked-in source is already consistently formatted.

## 3. Select Testnet and the deployer

```bash
sui client envs
sui client switch --env testnet
sui client active-env
sui client chain-identifier --format hex
sui client addresses
sui client switch --address <DEPLOYER_ALIAS_OR_ADDRESS>
sui client active-address
```

The expected environment and chain identifier are `testnet` and `4c78adac`.
Set the deployer only after checking that its keystore entry is the intended
custody account:

```bash
export DEPLOYER_ADDRESS="$(sui client active-address)"
```

## 4. Prepare Testnet gas

```bash
sui client gas "$DEPLOYER_ADDRESS"
```

If no gas coin is listed, the installed CLI supports:

```bash
sui client faucet --address "$DEPLOYER_ADDRESS"
sui client gas "$DEPLOYER_ADDRESS"
```

If the CLI faucet is rate-limited, use the official Sui Testnet faucet UI and
then rerun `sui client gas`. Testnet SUI has no real-world monetary value.

## 5. Pre-publish checklist

- [ ] Active environment is Testnet.
- [ ] Chain identifier is `4c78adac`.
- [ ] Active address is the intended deployer.
- [ ] Deployer has sufficient Testnet SUI.
- [ ] Git working tree and every Phase 9 change are understood.
- [ ] Final source has been reviewed.
- [ ] No secrets are inside Move source, `Move.toml`, or deployment files.
- [ ] No private keys, keystore files, mnemonics, or signatures are committed.
- [ ] No CLT/SUI exchange, redemption, rate, or swap exists.
- [ ] Build, lint, and all unit tests pass with warnings as errors.
- [ ] Key-only capability ownership and the nested Treasury authorities are understood.
- [ ] This is understood to be fresh version-1 publication, not an upgrade.
- [ ] The final `Move.lock` Testnet pin is understood.

Create a reviewable commit or tag before publication, but do not do this until
the diff is approved:

```bash
git add Move.toml Move.lock README.md ARCHITECTURE.md TESTNET_DEPLOYMENT.md sources tests deployments/testnet.env.example
git commit -m "feat: finalize on-chain game economy for testnet deployment"
```

## 6. Dry-run and publish

The installed CLI estimates gas with a dry run when `--gas-budget` is omitted.
First request an explicit non-executing dry run and inspect its status and gas
summary:

```bash
sui client publish . \
  --build-env testnet \
  --warnings-are-errors \
  --dry-run \
  --json | tee /tmp/game_economy-testnet-publish-dry-run.json
```

If policy requires a fixed budget, choose it from the dry-run computation cost,
storage cost, and current reference gas price with an operational margin. Do
not copy a stale budget from another network. Otherwise let the CLI estimate:

```bash
sui client publish . \
  --build-env testnet \
  --warnings-are-errors \
  --json | tee /tmp/game_economy-testnet-publish.json
```

This second command is the on-chain publication. Record the top-level
transaction digest and inspect all published/created/transferred changes:

```bash
jq '.digest, .effects.status, .objectChanges, .events' /tmp/game_economy-testnet-publish.json
jq '.. | objects | select(.type? == "published")' /tmp/game_economy-testnet-publish.json
```

Do not guess IDs. Copy them from `objectChanges`/effects by exact type:

```text
0x2::package::UpgradeCap
<PACKAGE_ID>::platform::AdminCap
<PACKAGE_ID>::reward::RewardCap
<PACKAGE_ID>::sui_reward::SuiRewardCap
<PACKAGE_ID>::game_credit::Treasury
0x2::coin_registry::Currency<<PACKAGE_ID>::game_credit::GAME_CREDIT>  (pending registration)
0x2::token::TokenPolicy<<PACKAGE_ID>::game_credit::GAME_CREDIT>
<PACKAGE_ID>::platform::PlatformConfig
<PACKAGE_ID>::reward::RewardConfig
<PACKAGE_ID>::reward::RewardRegistry
<PACKAGE_ID>::product_catalog::ProductCatalog
<PACKAGE_ID>::supply::SupplyStats
<PACKAGE_ID>::sui_reward::SuiRewardConfig
<PACKAGE_ID>::sui_reward::SuiRewardVault
```

For version 1, `ORIGINAL_PACKAGE_ID` equals `PACKAGE_ID` and
`PACKAGE_VERSION=1`. Copy the public template, fill it from actual effects, and
never add secrets:

```bash
cp deployments/testnet.env.example deployments/testnet.env
${EDITOR:-vi} deployments/testnet.env
source deployments/testnet.env
```

## 7. Finalize the Sui coin-registry registration

The pinned framework's one-time-witness currency flow deliberately has two
steps. Publication transfers a pending `Currency<GAME_CREDIT>` to the Sui coin
registry at `0xc`; anyone may finalize it into the canonical shared derived
object. Set the temporary ID from publish effects:

```bash
export PENDING_CURRENCY="<PENDING_CURRENCY_OBJECT_ID_FROM_PUBLISH>"

sui client call \
  --package 0x2 \
  --module coin_registry \
  --function finalize_registration \
  --type-args "$PACKAGE_ID::game_credit::GAME_CREDIT" \
  --args 0xc "$PENDING_CURRENCY" \
  --sender "$DEPLOYER_ADDRESS" \
  --json | tee /tmp/game_economy-currency-registration.json
```

Record this transaction digest and the newly created shared
`Currency<GAME_CREDIT>` ID as `CURRENCY`. The pending object is consumed and
must not remain in the deployment record.

```bash
jq '.digest, .effects.status, .objectChanges' /tmp/game_economy-currency-registration.json
export CURRENCY="<SHARED_CURRENCY_OBJECT_ID_FROM_REGISTRATION>"
sui client object "$CURRENCY" --json | jq
```

Verify `symbol = M`, `name = Mola Token`, `decimals = 2`, initial supply `0`,
and metadata-cap state `Deleted`. The metadata cap cannot be reclaimed.

## 8. Record reusable variables

Fill every value from publish/registration effects or object inspection:

```bash
export PACKAGE_ID="<PACKAGE_ID>"
export ORIGINAL_PACKAGE_ID="$PACKAGE_ID"
export PACKAGE_VERSION=1
export UPGRADE_CAP="<UPGRADE_CAP_OBJECT_ID>"
export ADMIN_CAP="<ADMIN_CAP_OBJECT_ID>"
export REWARD_CAP="<CLT_REWARD_CAP_OBJECT_ID>"
export SUI_REWARD_CAP="<SUI_REWARD_CAP_OBJECT_ID>"
export TREASURY="<TREASURY_OBJECT_ID>"
export CURRENCY="<CURRENCY_OBJECT_ID>"
export TOKEN_POLICY="<TOKEN_POLICY_OBJECT_ID>"
export PLATFORM_CONFIG="<PLATFORM_CONFIG_OBJECT_ID>"
export REWARD_CONFIG="<REWARD_CONFIG_OBJECT_ID>"
export REWARD_REGISTRY="<REWARD_REGISTRY_OBJECT_ID>"
export PRODUCT_CATALOG="<PRODUCT_CATALOG_OBJECT_ID>"
export SUPPLY_STATS="<SUPPLY_STATS_OBJECT_ID>"
export SUI_REWARD_CONFIG="<SUI_REWARD_CONFIG_OBJECT_ID>"
export SUI_REWARD_VAULT="<SUI_REWARD_VAULT_OBJECT_ID>"
```

## 9. Verify the published package and initialized objects

Goal: confirm version-1 code, singleton state, ownership, and zero initial
economic state.

Prerequisites: publish and coin-registry finalization succeeded; all variables
above are populated.

```bash
sui client object "$PACKAGE_ID" --json | jq
sui client verify-source . --build-env testnet
sui client object "$UPGRADE_CAP" --json | jq
sui client object "$ADMIN_CAP" --json | jq
sui client object "$REWARD_CAP" --json | jq
sui client object "$SUI_REWARD_CAP" --json | jq
sui client object "$TREASURY" --json | jq
sui client object "$CURRENCY" --json | jq
sui client object "$TOKEN_POLICY" --json | jq
sui client object "$PLATFORM_CONFIG" --json | jq
sui client object "$REWARD_CONFIG" --json | jq
sui client object "$REWARD_REGISTRY" --json | jq
sui client object "$PRODUCT_CATALOG" --json | jq
sui client object "$SUPPLY_STATS" --json | jq
sui client object "$SUI_REWARD_CONFIG" --json | jq
sui client object "$SUI_REWARD_VAULT" --json | jq
```

`verify-source` above verifies this package's local source against the
published `game_economy` bytecode. Do not add `--verify-deps` for this pinned
Testnet publication: `Move.lock` preserves the Sui framework revision used for
the build, while Testnet's system package at `0x2` can be upgraded later. In
that case dependency verification can correctly report framework module drift
even though `game_economy` itself matches on-chain. Do not rewrite `Move.lock`
to silence those dependency-only errors.

Expected state:

- package modules are exactly `game_credit`, `platform`, `product_catalog`,
  `purchase`, `reward`, `sui_reward`, and `supply`;
- deployer owns `UpgradeCap`, `AdminCap`, `RewardCap`, `SuiRewardCap`, and
  `Treasury` before any custody rotation;
- configuration, policy, registry, catalog, stats, and vault are shared;
- platform, CLT spending, CLT rewards, and SUI rewards are unpaused;
- CLT maximum is `100_000` base units; SUI maximum is
  `100_000_000_000` MIST;
- product/replay tables, spent balance, total supply, burn count, and SUI vault
  balance are zero;
- policy allows only `0x2::token::spend` with the private
  `game_credit::GamePurchaseRule`; transfer/to-coin/from-coin are not allowed;
- the nested Treasury/Policy capabilities are not separate deployer-owned
  objects.

Use the table IDs visible inside the shared objects to inspect dynamic fields:

```bash
sui client dynamic-field <PRODUCTS_TABLE_ID> --json | jq
sui client dynamic-field <PLAYER_PURCHASE_COUNTS_TABLE_ID> --json | jq
sui client dynamic-field <PROCESSED_ORDERS_TABLE_ID> --json | jq
sui client dynamic-field <CLT_REWARD_REPLAY_TABLE_ID> --json | jq
sui client dynamic-field <SUI_REWARD_REPLAY_TABLE_ID> --json | jq
```

All five lists must initially be empty.

## 10. Prepare role and player addresses

Use separate keystore addresses for integration testing when possible:

```bash
sui client addresses
export CLT_BACKEND="<CLT_BACKEND_ADDRESS>"
export SUI_BACKEND="<SUI_BACKEND_ADDRESS>"
export PLAYER="<TEST_PLAYER_ADDRESS>"
sui client faucet --address "$CLT_BACKEND"
sui client faucet --address "$SUI_BACKEND"
sui client faucet --address "$PLAYER"
sui client gas "$CLT_BACKEND"
sui client gas "$SUI_BACKEND"
sui client gas "$PLAYER"
```

If an address must be created, the installed syntax is, for example,
`sui client new-address ed25519 test-player word12`. Its recovery words are a
secret: store them securely and never paste them into source, logs, or the
deployment record.

Rotate CLT reward authority and its Treasury together, then rotate SUI reward
authority separately:

```bash
sui client call \
  --package "$PACKAGE_ID" \
  --module reward \
  --function transfer_reward_authority \
  --args "$REWARD_CAP" "$TREASURY" "$CLT_BACKEND" \
  --sender "$DEPLOYER_ADDRESS" \
  --json | tee /tmp/game_economy-clt-authority-transfer.json

sui client call \
  --package "$PACKAGE_ID" \
  --module sui_reward \
  --function transfer_sui_reward_authority \
  --args "$SUI_REWARD_CAP" "$SUI_BACKEND" \
  --sender "$DEPLOYER_ADDRESS" \
  --json | tee /tmp/game_economy-sui-authority-transfer.json
```

Verify object owners and both transfer events:

```bash
sui client object "$REWARD_CAP" --json | jq
sui client object "$TREASURY" --json | jq
sui client object "$SUI_REWARD_CAP" --json | jq
sui client tx-block "$(jq -r '.digest' /tmp/game_economy-clt-authority-transfer.json)" --json | jq '.events'
sui client tx-block "$(jq -r '.digest' /tmp/game_economy-sui-authority-transfer.json)" --json | jq '.events'
```

`RewardCap` and `Treasury` must be owned by `CLT_BACKEND`;
`SuiRewardCap` must be owned by `SUI_BACKEND`; `AdminCap` remains with the
deployer for these tests.

## 11. Create a test product

Goal: create the only source of product price/status/limit configuration and
verify its event and dynamic-field state.

Prerequisites: deployer owns `AdminCap`; catalog is empty. Use product ID `42`,
price `100` base units (`1.00 M`), global limit `2`, and per-player limit `2`:

```bash
export PRODUCT_ID=42
export PRODUCT_PRICE=100
export PRODUCT_SALES_LIMIT=2
export PRODUCT_PLAYER_LIMIT=2

sui client call \
  --package "$PACKAGE_ID" \
  --module product_catalog \
  --function create_product \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" "$PRODUCT_PRICE" "$PRODUCT_SALES_LIMIT" "$PRODUCT_PLAYER_LIMIT" \
  --sender "$DEPLOYER_ADDRESS" \
  --json | tee /tmp/game_economy-create-product.json
```

Expected state change: product `42` is active, sold count is `0`, and exactly
one `ProductCreated` event reports ID, price, and limits.

```bash
export CREATE_PRODUCT_TX="$(jq -r '.digest' /tmp/game_economy-create-product.json)"
sui client tx-block "$CREATE_PRODUCT_TX" --json | jq '.effects.status, .events'
sui client object "$PRODUCT_CATALOG" --json | jq
sui client dynamic-field <PRODUCTS_TABLE_ID_FROM_CATALOG> --json | jq
```

Creating ID `42` again must abort with
`product_catalog::EProductAlreadyExists` (code `0`); creating any product with
price `0` must abort with `EInvalidProductPrice` (code `2`). Use `--dry-run` on
the same call shape to test either failure without spending gas.

## 12. Generate unique 32-byte identifiers

Reward and order identifiers are Move `vector<u8>` values of exactly 32 bytes.
This shell helper produces the CLI literal expected by `--args`/PTB parsing:

```bash
move_id() {
  local marker="$1"
  local value="["
  local index
  for ((index = 0; index < 32; index++)); do
    if ((index > 0)); then value+=","; fi
    value+="${marker}u8"
  done
  value+="]"
  printf '%s' "$value"
}

export CLT_REWARD_ID="$(move_id 1)"
export PURCHASE_ORDER_ID="$(move_id 2)"
export SUI_REWARD_ID="$(move_id 3)"
```

Use a durable backend database uniqueness constraint in real operation. The
on-chain tables are the final replay backstop, not an ID generator.

## 13. Reward CLT to the player

Goal: prove bounded authorized minting, recipient delivery, replay protection,
and pause enforcement.

Prerequisites: `RewardCap` and `Treasury` belong to `CLT_BACKEND`; player and
backend have gas. Reward `1_000` base units (`10.00 M`):

```bash
export CLT_REWARD_AMOUNT=1000

sui client call \
  --package "$PACKAGE_ID" \
  --module reward \
  --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" "$CLT_REWARD_AMOUNT" "$CLT_REWARD_ID" \
  --sender "$CLT_BACKEND" \
  --json | tee /tmp/game_economy-clt-reward.json
```

Expected state change: total CLT supply increases by exactly `1_000`, the
player receives a `0x2::token::Token<$PACKAGE_ID::game_credit::GAME_CREDIT>`,
the reward ID is recorded once, and `CltRewarded` reports the recipient,
amount, and ID.

```bash
export CLT_REWARD_TX="$(jq -r '.digest' /tmp/game_economy-clt-reward.json)"
sui client tx-block "$CLT_REWARD_TX" --json | jq '.effects.status, .events, .objectChanges'
sui client object "$TREASURY" --json | jq
sui client object "$REWARD_REGISTRY" --json | jq
sui client objects "$PLAYER" --json | jq
```

Find the object whose type contains
`::token::Token<$PACKAGE_ID::game_credit::GAME_CREDIT>` and record its real ID:

```bash
export PLAYER_TOKEN="<PLAYER_TOKEN_OBJECT_ID_FROM_REWARD_EFFECTS>"
sui client object "$PLAYER_TOKEN" --json | jq
```

Intentional CLT reward failures:

1. Duplicate ID — rerun the same reward as a dry run. Expected
   `reward::ERewardAlreadyProcessed` (code `5`); supply, player objects, and
   replay-table length stay unchanged.

```bash
sui client call \
  --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 1 "$CLT_REWARD_ID" \
  --sender "$CLT_BACKEND" --dry-run --json | jq
```

2. Zero/oversized/invalid ID — expected `EZeroRewardAmount` (`2`),
   `ERewardTooLarge` (`3`), and `EInvalidRewardId` (`4`) respectively; no
   replay entry is consumed.

```bash
sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 0 "$(move_id 4)" \
  --sender "$CLT_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 100001 "$(move_id 5)" \
  --sender "$CLT_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 1 '[1u8,2u8]' \
  --sender "$CLT_BACKEND" --dry-run --json | jq
```

3. Dedicated pause — enable it as admin, confirm a unique reward dry run aborts
   with `reward::ERewardsPaused` (`0`), then unpause. The failed ID must remain
   usable after unpause.

```bash
export PAUSED_CLT_ID="$(move_id 6)"
sui client call --package "$PACKAGE_ID" --module reward --function pause_clt_rewards \
  --args "$REWARD_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 1 "$PAUSED_CLT_ID" \
  --sender "$CLT_BACKEND" --dry-run --json | jq
sui client call --package "$PACKAGE_ID" --module reward --function unpause_clt_rewards \
  --args "$REWARD_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
```

## 14. Purchase the product with CLT

Goal: split the closed-loop `Token`, spend the exact price, update catalog
accounting once, and emit the backend fulfillment event.

Prerequisites: product `42` is active and player token value is at least `100`.
Do not use `sui client split-coin`: `Token<GAME_CREDIT>` is not a `Coin`. Use
the installed PTB command and the framework's `token::split`:

```bash
sui client ptb \
  --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$PURCHASE_ORDER_ID" \
  --json | tee /tmp/game_economy-purchase.json
```

The mutable input token remains player-owned with value `900`; the split
payment object is consumed and cannot be reused. Expected shared state changes:

- policy spent balance increases by exactly `100`;
- product sold count becomes `1`;
- `(product 42, PLAYER)` purchase count becomes `1`;
- the order ID appears exactly once;
- `PurchaseCompleted` reports the actual sender, product `42`, amount `100`,
  and the exact order ID.

```bash
export PURCHASE_TX="$(jq -r '.digest' /tmp/game_economy-purchase.json)"
sui client tx-block "$PURCHASE_TX" --json | jq '.effects.status, .events, .objectChanges'
sui client object "$PLAYER_TOKEN" --json | jq
sui client object "$TOKEN_POLICY" --json | jq
sui client object "$PRODUCT_CATALOG" --json | jq
sui client dynamic-field <PRODUCTS_TABLE_ID_FROM_CATALOG> --json | jq
sui client dynamic-field <PLAYER_PURCHASE_COUNTS_TABLE_ID_FROM_CATALOG> --json | jq
sui client dynamic-field <PROCESSED_ORDERS_TABLE_ID_FROM_CATALOG> --json | jq
```

If a player token value equals the price, pass the whole token directly to
`purchase_catalog_product`; no split is required. Never attempt coin merge or
coin balance commands for a closed-loop `Token`.

## 15. Intentional purchase failures and atomicity

Goal: confirm every rejected transaction leaves the catalog, replay set,
policy spent balance, and player token unchanged.

Prerequisites: `PLAYER_TOKEN` now has `900`; product sold/player counts are
both `1`. Snapshot state before each dry run and compare it afterward:

```bash
sui client object "$PRODUCT_CATALOG" --json > /tmp/catalog-before.json
sui client object "$TOKEN_POLICY" --json > /tmp/policy-before.json
sui client object "$PLAYER_TOKEN" --json > /tmp/token-before.json
```

Wrong product (`EProductNotFound`, product-catalog code `1`):

```bash
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment 999 "$(move_id 7)" \
  --dry-run --json | jq
```

Underpayment and overpayment (`purchase::EInvalidPaymentAmount`, code `1`):

```bash
export UNDERPAYMENT=$((PRODUCT_PRICE - 1))
export OVERPAYMENT=$((PRODUCT_PRICE + 1))

sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$UNDERPAYMENT" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 8)" \
  --dry-run --json | jq

sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$OVERPAYMENT" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 9)" \
  --dry-run --json | jq
```

Zero payment (`purchase::EZeroPayment`, code `2`):

```bash
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::zero "<$PACKAGE_ID::game_credit::GAME_CREDIT>" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 10)" \
  --dry-run --json | jq
```

Duplicate order (`product_catalog::EPurchaseAlreadyProcessed`, code `9`):

```bash
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$PURCHASE_ORDER_ID" \
  --dry-run --json | jq
```

Disabled product (`EProductInactive`, product-catalog code `3`):

```bash
sui client call --package "$PACKAGE_ID" --module product_catalog --function disable_product \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" --sender "$DEPLOYER_ADDRESS" --json | jq
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 11)" \
  --dry-run --json | jq
sui client call --package "$PACKAGE_ID" --module product_catalog --function enable_product \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" --sender "$DEPLOYER_ADDRESS" --json | jq
```

Global limit (`EGlobalSalesLimitReached`, code `4`) and per-player limit
(`EPlayerPurchaseLimitReached`, code `5`):

```bash
sui client call --package "$PACKAGE_ID" --module product_catalog --function update_product_limits \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" 1 2 --sender "$DEPLOYER_ADDRESS" --json | jq
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 12)" \
  --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module product_catalog --function update_product_limits \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" 0 1 --sender "$DEPLOYER_ADDRESS" --json | jq
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 13)" \
  --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module product_catalog --function update_product_limits \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" 2 2 --sender "$DEPLOYER_ADDRESS" --json | jq
```

After each failure, verify sold/player/replay counts and spent/token values did
not change. A dry run cannot commit; these comparisons must show no change:

```bash
sui client object "$PRODUCT_CATALOG" --json > /tmp/catalog-after.json
sui client object "$TOKEN_POLICY" --json > /tmp/policy-after.json
sui client object "$PLAYER_TOKEN" --json > /tmp/token-after.json
diff -u /tmp/catalog-before.json /tmp/catalog-after.json || true
diff -u /tmp/policy-before.json /tmp/policy-after.json || true
diff -u /tmp/token-before.json /tmp/token-after.json || true
```

Catalog versions can legitimately differ because the disable/enable and limit
administration calls above are real successful transactions. The product's
sold count (`1`), player's count (`1`), order count (`1`), policy spent balance
(`100`), and token value (`900`) must remain unchanged by every failed purchase.

## 16. Flush spent CLT

Goal: prove the only burn path consumes the full policy spent balance and
reduces supply permanently.

Prerequisites: the successful purchase left `100` spent units; `CLT_BACKEND`
owns both `RewardCap` and `Treasury`.

```bash
sui client object "$TOKEN_POLICY" --json | jq
sui client object "$TREASURY" --json | jq
sui client object "$SUPPLY_STATS" --json | jq

sui client call \
  --package "$PACKAGE_ID" \
  --module supply \
  --function flush_spent_tokens \
  --args "$TOKEN_POLICY" "$SUPPLY_STATS" "$TREASURY" "$REWARD_CAP" \
  --sender "$CLT_BACKEND" \
  --json | tee /tmp/game_economy-clt-flush.json
```

Expected state change: spent balance becomes `0`, total supply falls from
`1_000` to `900`, cumulative burned becomes `100`, and `CltSpentFlushed`
reports all three values. No token returns to any address.

```bash
export CLT_FLUSH_TX="$(jq -r '.digest' /tmp/game_economy-clt-flush.json)"
sui client tx-block "$CLT_FLUSH_TX" --json | jq '.effects.status, .events'
sui client object "$TOKEN_POLICY" --json | jq
sui client object "$TREASURY" --json | jq
sui client object "$SUPPLY_STATS" --json | jq
```

A second empty flush dry run must abort with `supply::ENoSpentTokens` (code
`0`). A player cannot execute the call because it owns neither required object.

## 17. Fund the SUI reward vault

Goal: deposit explicitly funded native SUI without granting payout authority.

Prerequisites: funder has a gas coin greater than the deposit plus gas. Deposit
`100_000_000 MIST` (`0.1 SUI`) by splitting the PTB gas coin:

```bash
export VAULT_FUNDING_MIST=100000000
sui client object "$SUI_REWARD_VAULT" --json | jq

sui client ptb \
  --sender "$DEPLOYER_ADDRESS" \
  --split-coins gas "[$VAULT_FUNDING_MIST]" \
  --assign funding_coins \
  --move-call "$PACKAGE_ID::sui_reward::deposit_sui" "@$SUI_REWARD_VAULT" funding_coins.0 \
  --json | tee /tmp/game_economy-sui-vault-funding.json
```

Expected state change: vault balance becomes `100_000_000 MIST`; the funder
receives no capability or redeemable receipt; `SuiVaultFunded` reports the
deposit and balance after.

```bash
export SUI_FUND_TX="$(jq -r '.digest' /tmp/game_economy-sui-vault-funding.json)"
sui client tx-block "$SUI_FUND_TX" --json | jq '.effects.status, .events'
sui client object "$SUI_REWARD_VAULT" --json | jq
```

Zero funding is intentionally rejected with `sui_reward::EZeroDeposit` (code
`8`). Test it without committing:

```bash
sui client ptb --sender "$DEPLOYER_ADDRESS" \
  --move-call 0x2::coin::zero '<0x2::sui::SUI>' \
  --assign zero_coin \
  --move-call "$PACKAGE_ID::sui_reward::deposit_sui" "@$SUI_REWARD_VAULT" zero_coin \
  --dry-run --json | jq
```

There is no arbitrary withdrawal or vault-administration function. The only
outflow is a validated `sui_reward::reward_player` payout.

## 18. Send a SUI tournament reward

Goal: transfer only pre-funded SUI, prove the player/vault deltas and isolated
replay state, and confirm CLT is unchanged.

Prerequisites: vault holds `100_000_000 MIST`; `SUI_BACKEND` owns
`SuiRewardCap`. Pay `10_000_000 MIST` (`0.01 SUI`):

```bash
export SUI_REWARD_AMOUNT=10000000
sui client balance "$PLAYER" --coin-type 0x2::sui::SUI --json > /tmp/player-sui-before.json
sui client object "$SUI_REWARD_VAULT" --json > /tmp/vault-before.json
sui client object "$TREASURY" --json > /tmp/clt-treasury-before-sui-reward.json
sui client objects "$PLAYER" --json > /tmp/player-objects-before-sui-reward.json

sui client call \
  --package "$PACKAGE_ID" \
  --module sui_reward \
  --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" "$SUI_REWARD_AMOUNT" "$SUI_REWARD_ID" \
  --sender "$SUI_BACKEND" \
  --json | tee /tmp/game_economy-sui-reward.json

sui client balance "$PLAYER" --coin-type 0x2::sui::SUI --json > /tmp/player-sui-after.json
sui client object "$SUI_REWARD_VAULT" --json > /tmp/vault-after.json
sui client object "$TREASURY" --json > /tmp/clt-treasury-after-sui-reward.json
sui client objects "$PLAYER" --json > /tmp/player-objects-after-sui-reward.json
```

Expected state change: player SUI rises by exactly `10_000_000 MIST`, vault
falls from `100_000_000` to `90_000_000 MIST`, the ID is recorded once, and
`SuiRewarded` reports the player, amount, and ID. `SUI_BACKEND`, not the player,
pays transaction gas, so the player delta is directly comparable. CLT Treasury
supply and all existing CLT token values remain unchanged.

```bash
export SUI_REWARD_TX="$(jq -r '.digest' /tmp/game_economy-sui-reward.json)"
sui client tx-block "$SUI_REWARD_TX" --json | jq '.effects.status, .events, .objectChanges'
jq /tmp/player-sui-before.json /tmp/player-sui-after.json
jq /tmp/vault-before.json /tmp/vault-after.json
diff -u /tmp/clt-treasury-before-sui-reward.json /tmp/clt-treasury-after-sui-reward.json || true
```

Intentional SUI reward failures:

- Duplicate ID: `sui_reward::ERewardAlreadyProcessed` (`5`).
- Zero: `EZeroRewardAmount` (`2`).
- Above initial 100-SUI maximum: `ERewardTooLarge` (`3`).
- `100_000_000 MIST` after the payout: `EInsufficientVaultBalance` (`7`) because
  only `90_000_000` remains.
- Invalid two-byte ID: `EInvalidRewardId` (`4`).

```bash
sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 1 "$SUI_REWARD_ID" \
  --sender "$SUI_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 0 "$(move_id 14)" \
  --sender "$SUI_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 100000000001 "$(move_id 15)" \
  --sender "$SUI_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 100000000 "$(move_id 16)" \
  --sender "$SUI_BACKEND" --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 1 '[1u8,2u8]' \
  --sender "$SUI_BACKEND" --dry-run --json | jq
```

Inspect the vault before and after the entire failure block; its version,
balance, replay length, and the player's balances must be unchanged because all
five commands are dry runs.

## 19. Authorization boundary tests

Goal: prove that an ordinary address cannot construct privileged transactions.
Use `--sender "$PLAYER"` while supplying real cap IDs owned by other addresses.
Sui must reject input ownership before Move executes.

```bash
# Product administration: AdminCap belongs to DEPLOYER_ADDRESS.
sui client call --package "$PACKAGE_ID" --module product_catalog --function update_product_price \
  --args "$PRODUCT_CATALOG" "$ADMIN_CAP" "$PRODUCT_ID" 101 \
  --sender "$PLAYER" --dry-run --json | jq

# Global pause: AdminCap belongs to DEPLOYER_ADDRESS.
sui client call --package "$PACKAGE_ID" --module platform --function pause_platform \
  --args "$PLATFORM_CONFIG" "$ADMIN_CAP" \
  --sender "$PLAYER" --dry-run --json | jq

# CLT mint: RewardCap and Treasury belong to CLT_BACKEND.
sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 1 "$(move_id 17)" \
  --sender "$PLAYER" --dry-run --json | jq

# Spent CLT flush: same two CLT authority objects are not player-owned.
sui client call --package "$PACKAGE_ID" --module supply --function flush_spent_tokens \
  --args "$TOKEN_POLICY" "$SUPPLY_STATS" "$TREASURY" "$REWARD_CAP" \
  --sender "$PLAYER" --dry-run --json | jq

# SUI payout: SuiRewardCap belongs to SUI_BACKEND.
sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 1 "$(move_id 18)" \
  --sender "$PLAYER" --dry-run --json | jq
```

Expected result for each: an owned-input/authority error, no event, and no
object version change. A CLT `RewardCap` cannot substitute for `SuiRewardCap`,
and vice versa, because Move type checking rejects the call. No test-only API
should be added to weaken this guarantee.

Further static boundaries:

- only package initialization creates `AdminCap`, `RewardCap`, `SuiRewardCap`,
  or `Treasury`;
- `TreasuryCap<GAME_CREDIT>` and `TokenPolicyCap<GAME_CREDIT>` are private
  nested fields with no extractor;
- no public policy-rule administration function exists;
- no public SUI vault extraction function exists;
- all four privileged owned objects are `key` without `store`, so generic
  transfer/wrapping/sharing functions cannot move them.

## 20. Pause behavior

### Global pause

Goal: stop all three player-facing economic flows while leaving deposits and
administration available.

```bash
export GLOBAL_PAUSE_CLT_ID="$(move_id 19)"
export GLOBAL_PAUSE_ORDER_ID="$(move_id 20)"
export GLOBAL_PAUSE_SUI_ID="$(move_id 21)"

sui client call --package "$PACKAGE_ID" --module platform --function pause_platform \
  --args "$PLATFORM_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq

# Expected reward::EPlatformPaused (1).
sui client call --package "$PACKAGE_ID" --module reward --function reward_player \
  --args "$TREASURY" "$PLATFORM_CONFIG" "$REWARD_CONFIG" "$REWARD_REGISTRY" "$REWARD_CAP" "$PLAYER" 1 "$GLOBAL_PAUSE_CLT_ID" \
  --sender "$CLT_BACKEND" --dry-run --json | jq

# Expected purchase::EPlatformPaused (0).
sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$GLOBAL_PAUSE_ORDER_ID" \
  --dry-run --json | jq

# Expected sui_reward::EPlatformPaused (0).
sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 1 "$GLOBAL_PAUSE_SUI_ID" \
  --sender "$SUI_BACKEND" --dry-run --json | jq

# Depositing is intentionally still constructible while paused; dry-run only.
sui client ptb --sender "$DEPLOYER_ADDRESS" --split-coins gas '[1]' \
  --assign funding_coins \
  --move-call "$PACKAGE_ID::sui_reward::deposit_sui" "@$SUI_REWARD_VAULT" funding_coins.0 \
  --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module platform --function unpause_platform \
  --args "$PLATFORM_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
```

After unpause, dry-running the three unique protected actions must reach success
(assuming limits/balances are otherwise valid), proving their IDs were not
consumed by paused attempts.

### CLT spending pause

```bash
sui client call --package "$PACKAGE_ID" --module platform --function pause_clt_spending \
  --args "$PLATFORM_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq

sui client ptb --sender "$PLAYER" \
  --move-call 0x2::token::split "<$PACKAGE_ID::game_credit::GAME_CREDIT>" "@$PLAYER_TOKEN" "$PRODUCT_PRICE" \
  --assign payment \
  --move-call "$PACKAGE_ID::purchase::purchase_catalog_product" "@$PLATFORM_CONFIG" "@$PRODUCT_CATALOG" "@$TOKEN_POLICY" payment "$PRODUCT_ID" "$(move_id 22)" \
  --dry-run --json | jq

sui client call --package "$PACKAGE_ID" --module platform --function unpause_clt_spending \
  --args "$PLATFORM_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
```

Expected failure is `purchase::ECltSpendingPaused` (`5`). CLT mint rewards and
SUI rewards remain logically independent; dry-run one unique reward in each
domain while this pause is active if that isolation needs operational proof.

### SUI reward pause

```bash
sui client call --package "$PACKAGE_ID" --module sui_reward --function pause_sui_rewards \
  --args "$SUI_REWARD_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
sui client call --package "$PACKAGE_ID" --module sui_reward --function reward_player \
  --args "$PLATFORM_CONFIG" "$SUI_REWARD_CONFIG" "$SUI_REWARD_VAULT" "$SUI_REWARD_CAP" "$PLAYER" 1 "$(move_id 23)" \
  --sender "$SUI_BACKEND" --dry-run --json | jq
sui client call --package "$PACKAGE_ID" --module sui_reward --function unpause_sui_rewards \
  --args "$SUI_REWARD_CONFIG" "$ADMIN_CAP" --sender "$DEPLOYER_ADDRESS" --json | jq
```

Expected failure is `sui_reward::ERewardsPaused` (`1`). Vault deposits, CLT
rewards, and purchases are not blocked by this domain pause.

The CLT reward-specific pause and unpause commands are in section 13. Repeating
pause or unpause in the same state intentionally aborts with the matching
`AlreadyPaused`/`NotPaused` error; this catches operational state mistakes.

## 21. Event verification

Never treat transaction success alone as backend fulfillment. For every real
transaction, record its digest and inspect the event array:

```bash
sui client tx-block "$CREATE_PRODUCT_TX" --json | jq '.events'
sui client tx-block "$CLT_REWARD_TX" --json | jq '.events'
sui client tx-block "$PURCHASE_TX" --json | jq '.events'
sui client tx-block "$CLT_FLUSH_TX" --json | jq '.events'
sui client tx-block "$SUI_FUND_TX" --json | jq '.events'
sui client tx-block "$SUI_REWARD_TX" --json | jq '.events'
```

Verify exact type and parsed JSON fields:

| Event | Required values |
|---|---|
| `ProductCreated` | `product_id`, `price`, `sales_limit`, `per_player_limit` |
| `CltRewarded` | `recipient`, `amount`, `reward_id` |
| `PurchaseCompleted` | `buyer`, `product_id`, `amount`, `order_id` |
| `CltSpentFlushed` | `amount`, `total_supply_after`, `total_burned` |
| `SuiVaultFunded` | `amount`, `balance_after` |
| `SuiRewarded` | `recipient`, `amount`, `reward_id` |

The sender in transaction metadata must also match the operational role. Store
the transaction digest as the durable event cursor/back-reference in backend
records.

## 22. Final object ownership inspection

```bash
sui client object "$UPGRADE_CAP" --json | jq '.data.owner'
sui client object "$ADMIN_CAP" --json | jq '.data.owner'
sui client object "$REWARD_CAP" --json | jq '.data.owner'
sui client object "$TREASURY" --json | jq '.data.owner'
sui client object "$SUI_REWARD_CAP" --json | jq '.data.owner'
sui client object "$CURRENCY" --json | jq '.data.owner'
sui client object "$TOKEN_POLICY" --json | jq '.data.owner'
sui client object "$PLATFORM_CONFIG" --json | jq '.data.owner'
sui client object "$REWARD_CONFIG" --json | jq '.data.owner'
sui client object "$REWARD_REGISTRY" --json | jq '.data.owner'
sui client object "$PRODUCT_CATALOG" --json | jq '.data.owner'
sui client object "$SUPPLY_STATS" --json | jq '.data.owner'
sui client object "$SUI_REWARD_CONFIG" --json | jq '.data.owner'
sui client object "$SUI_REWARD_VAULT" --json | jq '.data.owner'
```

Expected final Testnet ownership:

| Object/capability | Expected ownership | Reason |
|---|---|---|
| `UpgradeCap` | Deployer/high-security address-owned | Controls future code upgrades. |
| `AdminCap` | Deployer/admin address-owned | Product and pause/limit administration only. |
| `RewardCap` | `CLT_BACKEND` address-owned | CLT mint and spent flush authorization. |
| `Treasury` | `CLT_BACKEND` address-owned | Paired protected framework authority for CLT. |
| `SuiRewardCap` | `SUI_BACKEND` address-owned | Separate native-SUI payout authorization. |
| `Currency<GAME_CREDIT>` | Shared | Canonical coin-registry metadata after finalization. |
| `TokenPolicy<GAME_CREDIT>` | Shared | Every purchase/flush must update official spent balance. |
| `PlatformConfig` | Shared | Protected flows need common pause state. |
| `RewardConfig` | Shared | Rewards read common pause/limit state. |
| `RewardRegistry` | Shared | Global CLT reward replay protection. |
| `ProductCatalog` | Shared | Global products, counters, and order replay. |
| `SupplyStats` | Shared | Auditable cumulative flush accounting. |
| `SuiRewardConfig` | Shared | SUI payouts read common pause/limit state. |
| `SuiRewardVault` | Shared | Funding and payouts mutate one prefunded balance/replay set. |

The expected shared-object contention points are `RewardRegistry` for every CLT
reward, `ProductCatalog` and `TokenPolicy` for purchases, `SuiRewardVault` for
funding/payouts, and the policy/stats pair for flushes. Monitor Testnet latency
and congestion before Mainnet load assumptions.

## 23. Record and commit deployment artifacts

Update `deployments/testnet.env` with only the public values listed in
`deployments/testnet.env.example`, including both transaction digests. Confirm
the package-management files produced or updated by the CLI:

```bash
git status --short
sed -n '1,240p' Published.toml
sed -n '1,240p' Move.lock
sui client object "$PACKAGE_ID" --json | jq
sui client objects "$DEPLOYER_ADDRESS" --json | jq
sui client objects "$CLT_BACKEND" --json | jq
sui client objects "$SUI_BACKEND" --json | jq
```

Commit `Published.toml`, the post-publish `Move.lock`, and
`deployments/testnet.env` after independent verification. The environment file
is safe to commit because it contains public network identifiers and
transaction digests only. Do not commit `/tmp` response files unless your
project explicitly archives public transaction responses.

## 24. Troubleshooting and clean deployment policy

- `Object not found` usually means wrong network or a copied ID from another
  publication. Check `active-env`, chain ID, and the object on Testnet.
- `IncorrectUserSignature`/input ownership errors mean the `--sender` key does
  not own an address-owned cap/Treasury/gas object. Inspect `.data.owner`.
- A shared-object version error means the client built from stale state; rerun
  object inspection and reconstruct the transaction using the stable object ID.
- Quote PTB type arguments (`"<...>"`) and vector/array literals. Reward/order
  vectors must contain exactly 32 `u8` elements.
- A player CLT is `Token<GAME_CREDIT>`, not `Coin<GAME_CREDIT>`. Use
  `0x2::token::split` inside a PTB, not coin CLI commands.
- If coin metadata appears pending under `0xc`, run section 7 once. Calling it
  again with the consumed pending object must fail.
- `ERewardAlreadyProcessed`/`EPurchaseAlreadyProcessed` means the backend
  reused an ID. Generate a new durable unique ID; never retry with the same ID
  after a confirmed success.
- `EProductInactive` or a limit error is catalog state, not a token failure.
  Inspect product and per-player dynamic fields.
- `EInsufficientVaultBalance` requires another explicit SUI deposit. It never
  permits minting, CLT redemption, or bypassing the configured maximum.
- If automatic gas estimation fails, rerun the identical call with `--dry-run`
  and inspect RPC/gas status before setting a reviewed `--gas-budget` in MIST.
- The installed `sui move format` command requires external `prettier-move`;
  its absence is not a build failure.

If publish dry-run or execution fails before effects commit, correct the cause
and retry; no package exists from a failed transaction. After a successful
publication, the package is immutable versioned on-chain: do not delete
`Published.toml` or pretend it never happened. The canonical next deployment
operation is a compatibility-reviewed upgrade using the recorded
`UpgradeCap`, for which this CLI's syntax is:

```bash
sui client upgrade . \
  --upgrade-capability "$UPGRADE_CAP" \
  --build-env testnet \
  --warnings-are-errors \
  --dry-run \
  --json
```

That command is documentation only; there is no upgrade to perform for this
fresh version-1 release. A deliberately separate disposable publication must
use a separate reviewed publication identity and deployment record, never
overwrite the canonical Testnet record.

## Mainnet custody recommendations

- Do not keep `UpgradeCap`, `AdminCap`, CLT reward custody, and SUI reward
  custody in one hot wallet.
- Keep `RewardCap` and `Treasury` together under a dedicated CLT backend signer.
- Protect `SuiRewardCap` separately because it can release prefunded native SUI.
- Keep `AdminCap` and especially `UpgradeCap` in stronger custody; consider Sui
  multisig appropriate to operational response requirements.
- Back up recovery material offline, test recovery, rotate compromised roles
  through their explicit transfer functions, and never commit keystore files.
- Add backend anti-cheat, rate monitoring, alerting, and independent event
  reconciliation before Mainnet; those controls are intentionally off-chain.

## Deployment record template

The authoritative checked-in template is
`deployments/testnet.env.example`. It contains:

```text
NETWORK=testnet
CHAIN_ID=4c78adac
PACKAGE_ID=
ORIGINAL_PACKAGE_ID=
PACKAGE_VERSION=1
DEPLOYER_ADDRESS=
PUBLISH_TX_DIGEST=
CURRENCY_REGISTRATION_TX_DIGEST=

UPGRADE_CAP=
ADMIN_CAP=
CLT_REWARD_CAP=
SUI_REWARD_CAP=
TREASURY=

CURRENCY=
TOKEN_POLICY=
PLATFORM_CONFIG=
REWARD_CONFIG=
REWARD_REGISTRY=
PRODUCT_CATALOG=
SUPPLY_STATS=
SUI_REWARD_CONFIG=
SUI_REWARD_VAULT=
```
