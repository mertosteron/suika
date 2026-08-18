module game_economy::reward;

use game_economy::game_credit::{Self, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use sui::event;
use sui::table::{Self, Table};

const REWARD_ID_LENGTH: u64 = 32;
const INITIAL_MAX_REWARD_PER_TRANSACTION: u64 = 100_000;

const ERewardsPaused: u64 = 0;
const EPlatformPaused: u64 = 1;
const EZeroRewardAmount: u64 = 2;
const ERewardTooLarge: u64 = 3;
const EInvalidRewardId: u64 = 4;
const ERewardAlreadyProcessed: u64 = 5;
const EInvalidMaxReward: u64 = 6;
const ERewardsAlreadyPaused: u64 = 7;
const ERewardsNotPaused: u64 = 8;

/// Authority for validated CLT rewards and spent-token flushing.
///
/// `key` without `store` prevents generic transfer, wrapping, or sharing. The
/// supported transfer path moves this capability and Treasury together.
public struct RewardCap has key {
    id: UID,
}

/// Shared CLT reward pause and per-transaction limit.
public struct RewardConfig has key {
    id: UID,
    rewards_paused: bool,
    max_reward_per_transaction: u64,
}

/// Global CLT reward replay set for this package publication.
public struct RewardRegistry has key {
    id: UID,
    processed: Table<vector<u8>, bool>,
}

public struct CltRewarded has copy, drop {
    recipient: address,
    amount: u64,
    reward_id: vector<u8>,
}

public struct CltRewardsPauseChanged has copy, drop {
    paused: bool,
}

public struct MaxCltRewardChanged has copy, drop {
    old_limit: u64,
    new_limit: u64,
}

public struct RewardAuthorityTransferred has copy, drop {
    previous_owner: address,
    new_owner: address,
}

fun init(ctx: &mut TxContext) {
    let publisher = ctx.sender();
    transfer::transfer(
        RewardCap { id: object::new(ctx) },
        publisher,
    );
    transfer::share_object(RewardConfig {
        id: object::new(ctx),
        rewards_paused: false,
        max_reward_per_transaction: INITIAL_MAX_REWARD_PER_TRANSACTION,
    });
    transfer::share_object(RewardRegistry {
        id: object::new(ctx),
        processed: table::new(ctx),
    });
}

/// Rotates the CLT reward capability and Treasury as one custody unit.
public fun transfer_reward_authority(
    reward_cap: RewardCap,
    treasury: Treasury,
    recipient: address,
    ctx: &mut TxContext,
) {
    let previous_owner = ctx.sender();
    game_credit::transfer_for_rewards(treasury, recipient);
    transfer::transfer(reward_cap, recipient);
    event::emit(RewardAuthorityTransferred {
        previous_owner,
        new_owner: recipient,
    });
}

/// Mints one bounded, replay-protected CLT reward to an explicit recipient.
public fun reward_player(
    treasury: &mut Treasury,
    platform_config: &PlatformConfig,
    reward_config: &RewardConfig,
    reward_registry: &mut RewardRegistry,
    _reward_cap: &RewardCap,
    recipient: address,
    amount: u64,
    reward_id: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(!platform::paused(platform_config), EPlatformPaused);
    assert!(!reward_config.rewards_paused, ERewardsPaused);
    assert!(amount > 0, EZeroRewardAmount);
    assert!(
        amount <= reward_config.max_reward_per_transaction,
        ERewardTooLarge,
    );
    assert!(reward_id.length() == REWARD_ID_LENGTH, EInvalidRewardId);
    assert!(
        !table::contains(&reward_registry.processed, reward_id),
        ERewardAlreadyProcessed,
    );

    table::add(&mut reward_registry.processed, reward_id, true);
    game_credit::mint_and_transfer_reward(treasury, recipient, amount, ctx);
    event::emit(CltRewarded {
        recipient,
        amount,
        reward_id,
    });
}

public fun pause_clt_rewards(config: &mut RewardConfig, _admin_cap: &AdminCap) {
    assert!(!config.rewards_paused, ERewardsAlreadyPaused);
    config.rewards_paused = true;
    event::emit(CltRewardsPauseChanged { paused: true });
}

public fun unpause_clt_rewards(config: &mut RewardConfig, _admin_cap: &AdminCap) {
    assert!(config.rewards_paused, ERewardsNotPaused);
    config.rewards_paused = false;
    event::emit(CltRewardsPauseChanged { paused: false });
}

public fun update_max_reward_per_transaction(
    config: &mut RewardConfig,
    _admin_cap: &AdminCap,
    new_limit: u64,
) {
    assert!(new_limit > 0, EInvalidMaxReward);
    let old_limit = config.max_reward_per_transaction;
    config.max_reward_per_transaction = new_limit;
    event::emit(MaxCltRewardChanged {
        old_limit,
        new_limit,
    });
}

#[test_only]
public fun rewards_paused(config: &RewardConfig): bool {
    config.rewards_paused
}

#[test_only]
public fun max_reward_per_transaction(config: &RewardConfig): u64 {
    config.max_reward_per_transaction
}

#[test_only]
public fun initial_max_reward_per_transaction(): u64 {
    INITIAL_MAX_REWARD_PER_TRANSACTION
}

#[test_only]
public fun reward_id_length(): u64 {
    REWARD_ID_LENGTH
}

#[test_only]
public fun is_processed(
    registry: &RewardRegistry,
    reward_id: vector<u8>,
): bool {
    table::contains(&registry.processed, reward_id)
}

#[test_only]
public fun processed_count(registry: &RewardRegistry): u64 {
    registry.processed.length()
}

#[test_only]
public fun rewarded_recipient(event: &CltRewarded): address {
    event.recipient
}

#[test_only]
public fun rewarded_amount(event: &CltRewarded): u64 {
    event.amount
}

#[test_only]
public fun rewarded_id(event: &CltRewarded): vector<u8> {
    event.reward_id
}

#[test_only]
public fun pause_changed_value(event: &CltRewardsPauseChanged): bool {
    event.paused
}

#[test_only]
public fun max_changed_old_limit(event: &MaxCltRewardChanged): u64 {
    event.old_limit
}

#[test_only]
public fun max_changed_new_limit(event: &MaxCltRewardChanged): u64 {
    event.new_limit
}

#[test_only]
public fun authority_previous_owner(event: &RewardAuthorityTransferred): address {
    event.previous_owner
}

#[test_only]
public fun authority_new_owner(event: &RewardAuthorityTransferred): address {
    event.new_owner
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
