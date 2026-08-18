module game_economy::sui_reward;

use game_economy::platform::{Self, AdminCap, PlatformConfig};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};

const REWARD_ID_LENGTH: u64 = 32;
const MIST_PER_SUI: u64 = 1_000_000_000;
const INITIAL_MAX_REWARD_PER_TRANSACTION: u64 = 100 * MIST_PER_SUI;

const EPlatformPaused: u64 = 0;
const ERewardsPaused: u64 = 1;
const EZeroRewardAmount: u64 = 2;
const ERewardTooLarge: u64 = 3;
const EInvalidRewardId: u64 = 4;
const ERewardAlreadyProcessed: u64 = 5;
const EInvalidMaxReward: u64 = 6;
const EInsufficientVaultBalance: u64 = 7;
const EZeroDeposit: u64 = 8;
const ERewardsAlreadyPaused: u64 = 9;
const ERewardsNotPaused: u64 = 10;

/// Dedicated authority for bounded, replay-protected SUI rewards.
///
/// `key` without `store` prevents generic transfer, wrapping, or sharing.
public struct SuiRewardCap has key {
    id: UID,
}

/// Shared SUI reward pause and per-transaction limit.
public struct SuiRewardConfig has key {
    id: UID,
    rewards_paused: bool,
    max_reward_per_transaction: u64,
}

/// Shared custody for explicitly deposited SUI and its payout replay set.
public struct SuiRewardVault has key {
    id: UID,
    balance: Balance<SUI>,
    processed: Table<vector<u8>, bool>,
}

public struct SuiVaultFunded has copy, drop {
    amount: u64,
    balance_after: u64,
}

public struct SuiRewarded has copy, drop {
    recipient: address,
    amount: u64,
    reward_id: vector<u8>,
}

public struct SuiRewardsPauseChanged has copy, drop {
    paused: bool,
}

public struct MaxSuiRewardChanged has copy, drop {
    old_limit: u64,
    new_limit: u64,
}

public struct SuiRewardAuthorityTransferred has copy, drop {
    previous_owner: address,
    new_owner: address,
}

fun init(ctx: &mut TxContext) {
    let publisher = ctx.sender();
    transfer::transfer(
        SuiRewardCap { id: object::new(ctx) },
        publisher,
    );
    transfer::share_object(SuiRewardConfig {
        id: object::new(ctx),
        rewards_paused: false,
        max_reward_per_transaction: INITIAL_MAX_REWARD_PER_TRANSACTION,
    });
    transfer::share_object(SuiRewardVault {
        id: object::new(ctx),
        balance: balance::zero(),
        processed: table::new(ctx),
    });
}

public fun transfer_sui_reward_authority(
    reward_cap: SuiRewardCap,
    recipient: address,
    ctx: &mut TxContext,
) {
    let previous_owner = ctx.sender();
    transfer::transfer(reward_cap, recipient);
    event::emit(SuiRewardAuthorityTransferred {
        previous_owner,
        new_owner: recipient,
    });
}

/// Adds caller-supplied SUI. Deposits grant no authority and return no funds.
public fun deposit_sui(
    vault: &mut SuiRewardVault,
    payment: Coin<SUI>,
) {
    let amount = payment.value();
    assert!(amount > 0, EZeroDeposit);

    vault.balance.join(payment.into_balance());
    event::emit(SuiVaultFunded {
        amount,
        balance_after: vault.balance.value(),
    });
}

/// Pays one bounded reward from SUI already held by the vault.
public fun reward_player(
    platform_config: &PlatformConfig,
    reward_config: &SuiRewardConfig,
    vault: &mut SuiRewardVault,
    _reward_cap: &SuiRewardCap,
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
        !table::contains(&vault.processed, reward_id),
        ERewardAlreadyProcessed,
    );
    assert!(vault.balance.value() >= amount, EInsufficientVaultBalance);

    table::add(&mut vault.processed, reward_id, true);
    let payout = coin::from_balance(vault.balance.split(amount), ctx);
    transfer::public_transfer(payout, recipient);
    event::emit(SuiRewarded {
        recipient,
        amount,
        reward_id,
    });
}

public fun pause_sui_rewards(
    config: &mut SuiRewardConfig,
    _admin_cap: &AdminCap,
) {
    assert!(!config.rewards_paused, ERewardsAlreadyPaused);
    config.rewards_paused = true;
    event::emit(SuiRewardsPauseChanged { paused: true });
}

public fun unpause_sui_rewards(
    config: &mut SuiRewardConfig,
    _admin_cap: &AdminCap,
) {
    assert!(config.rewards_paused, ERewardsNotPaused);
    config.rewards_paused = false;
    event::emit(SuiRewardsPauseChanged { paused: false });
}

public fun update_max_reward_per_transaction(
    config: &mut SuiRewardConfig,
    _admin_cap: &AdminCap,
    new_limit: u64,
) {
    assert!(new_limit > 0, EInvalidMaxReward);
    let old_limit = config.max_reward_per_transaction;
    config.max_reward_per_transaction = new_limit;
    event::emit(MaxSuiRewardChanged {
        old_limit,
        new_limit,
    });
}

#[test_only]
public fun balance(vault: &SuiRewardVault): u64 {
    vault.balance.value()
}

#[test_only]
public fun rewards_paused(config: &SuiRewardConfig): bool {
    config.rewards_paused
}

#[test_only]
public fun max_reward_per_transaction(config: &SuiRewardConfig): u64 {
    config.max_reward_per_transaction
}

#[test_only]
public fun initial_max_reward_per_transaction(): u64 {
    INITIAL_MAX_REWARD_PER_TRANSACTION
}

#[test_only]
public fun mist_per_sui(): u64 {
    MIST_PER_SUI
}

#[test_only]
public fun reward_id_length(): u64 {
    REWARD_ID_LENGTH
}

#[test_only]
public fun is_processed(
    vault: &SuiRewardVault,
    reward_id: vector<u8>,
): bool {
    table::contains(&vault.processed, reward_id)
}

#[test_only]
public fun processed_count(vault: &SuiRewardVault): u64 {
    vault.processed.length()
}

#[test_only]
public fun funded_amount(event: &SuiVaultFunded): u64 { event.amount }

#[test_only]
public fun funded_balance_after(event: &SuiVaultFunded): u64 {
    event.balance_after
}

#[test_only]
public fun rewarded_recipient(event: &SuiRewarded): address { event.recipient }

#[test_only]
public fun rewarded_amount(event: &SuiRewarded): u64 { event.amount }

#[test_only]
public fun rewarded_id(event: &SuiRewarded): vector<u8> { event.reward_id }

#[test_only]
public fun pause_changed_value(event: &SuiRewardsPauseChanged): bool {
    event.paused
}

#[test_only]
public fun max_changed_old_limit(event: &MaxSuiRewardChanged): u64 {
    event.old_limit
}

#[test_only]
public fun max_changed_new_limit(event: &MaxSuiRewardChanged): u64 {
    event.new_limit
}

#[test_only]
public fun authority_previous_owner(event: &SuiRewardAuthorityTransferred): address {
    event.previous_owner
}

#[test_only]
public fun authority_new_owner(event: &SuiRewardAuthorityTransferred): address {
    event.new_owner
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
