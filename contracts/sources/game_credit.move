module game_economy::game_credit;

use sui::coin::TreasuryCap;
use sui::coin_registry;
use sui::token::{Self, Token, TokenPolicy, TokenPolicyCap};

const DECIMALS: u8 = 2;
const SYMBOL: vector<u8> = b"M";
const NAME: vector<u8> = b"Mola Token";
const DESCRIPTION: vector<u8> = b"Closed-loop utility token for the game economy";
const ICON_URL: vector<u8> = b"";

/// One-time witness for the game's single closed-loop currency.
public struct GAME_CREDIT has drop {}

/// Private witness for the only policy-approved spend action.
public struct GamePurchaseRule has drop {}

/// Address-owned custody for mint, policy-confirmation, and spent-token flush
/// authority. Its framework capabilities cannot be extracted from this module.
///
/// `key` without `store` prevents generic transfer, wrapping, or sharing.
public struct Treasury has key {
    id: UID,
    treasury_cap: TreasuryCap<GAME_CREDIT>,
    policy_cap: TokenPolicyCap<GAME_CREDIT>,
}

fun init(otw: GAME_CREDIT, ctx: &mut TxContext) {
    let administrator = ctx.sender();
    let (currency, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        DECIMALS,
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        ctx,
    );
    let (mut policy, policy_cap) = token::new_policy(&treasury_cap, ctx);
    policy.add_rule_for_action<GAME_CREDIT, GamePurchaseRule>(
        &policy_cap,
        token::spend_action(),
        ctx,
    );

    // Currency metadata is immutable after publication. Deleting MetadataCap
    // removes unused metadata authority instead of retaining another secret.
    coin_registry::finalize_and_delete_metadata_cap(currency, ctx);
    token::share_policy(policy);

    transfer::transfer(
        Treasury {
            id: object::new(ctx),
            treasury_cap,
            policy_cap,
        },
        administrator,
    );
}

#[test_only]
public fun decimals(): u8 {
    DECIMALS
}

#[test_only]
public fun symbol(): vector<u8> {
    SYMBOL
}

#[test_only]
public fun name(): vector<u8> {
    NAME
}

#[test_only]
public fun description(): vector<u8> {
    DESCRIPTION
}

public(package) fun total_supply(treasury: &Treasury): u64 {
    treasury.treasury_cap.total_supply()
}

/// Keeps Treasury custody aligned with the CLT reward capability.
public(package) fun transfer_for_rewards(treasury: Treasury, recipient: address) {
    transfer::transfer(treasury, recipient);
}

/// Mints a closed-loop Token and transfers it through the protected policy cap.
public(package) fun mint_and_transfer_reward(
    treasury: &mut Treasury,
    recipient: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    let reward = token::mint(&mut treasury.treasury_cap, amount, ctx);
    let transfer_request = token::transfer(reward, recipient, ctx);
    let (_, _, _, _) = token::confirm_with_policy_cap(
        &treasury.policy_cap,
        transfer_request,
        ctx,
    );
}

/// Burns the complete TokenPolicy spent balance through TreasuryCap.
public(package) fun flush_spent_tokens(
    treasury: &mut Treasury,
    policy: &mut TokenPolicy<GAME_CREDIT>,
    ctx: &mut TxContext,
): u64 {
    policy.flush(&mut treasury.treasury_cap, ctx)
}

/// Confirms one package-approved purchase payment into policy spent balance.
public(package) fun consume_purchase_payment(
    policy: &mut TokenPolicy<GAME_CREDIT>,
    payment: Token<GAME_CREDIT>,
    ctx: &mut TxContext,
): (u64, address) {
    let mut request = payment.spend(ctx);
    token::add_approval(GamePurchaseRule {}, &mut request, ctx);
    let (_, amount, buyer, _) = policy.confirm_request_mut(request, ctx);
    (amount, buyer)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(GAME_CREDIT {}, ctx);
}
