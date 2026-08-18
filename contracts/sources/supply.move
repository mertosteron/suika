module game_economy::supply;

use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::reward::RewardCap;
use sui::event;
use sui::token::TokenPolicy;

const ENoSpentTokens: u64 = 0;
const EBurnAccountingOverflow: u64 = 1;
const EInvalidBurnAmount: u64 = 2;

/// Cumulative burn accounting, mutated only by authorized spent-token flushes.
public struct SupplyStats has key {
    id: UID,
    total_burned: u64,
}

public struct CltSpentFlushed has copy, drop {
    amount: u64,
    total_supply_after: u64,
    total_burned: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(SupplyStats {
        id: object::new(ctx),
        total_burned: 0,
    });
}

/// Burns the complete policy spent balance and updates supply accounting.
public fun flush_spent_tokens(
    policy: &mut TokenPolicy<GAME_CREDIT>,
    stats: &mut SupplyStats,
    treasury: &mut Treasury,
    _reward_cap: &RewardCap,
    ctx: &mut TxContext,
): u64 {
    let spent = policy.spent_balance();
    assert!(spent > 0, ENoSpentTokens);
    assert!(
        stats.total_burned <= std::u64::max_value!() - spent,
        EBurnAccountingOverflow,
    );

    let burned = game_credit::flush_spent_tokens(treasury, policy, ctx);
    assert!(burned == spent, EInvalidBurnAmount);

    stats.total_burned = stats.total_burned + burned;
    let total_supply_after = game_credit::total_supply(treasury);
    event::emit(CltSpentFlushed {
        amount: burned,
        total_supply_after,
        total_burned: stats.total_burned,
    });
    burned
}

#[test_only]
public fun total_burned(stats: &SupplyStats): u64 {
    stats.total_burned
}

#[test_only]
public fun flushed_amount(event: &CltSpentFlushed): u64 { event.amount }

#[test_only]
public fun flushed_total_supply_after(event: &CltSpentFlushed): u64 {
    event.total_supply_after
}

#[test_only]
public fun flushed_total_burned(event: &CltSpentFlushed): u64 {
    event.total_burned
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_total_burned_for_testing(stats: &mut SupplyStats, value: u64) {
    stats.total_burned = value;
}
