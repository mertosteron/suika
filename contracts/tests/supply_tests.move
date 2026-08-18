#[test_only]
module game_economy::supply_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::product_catalog::{Self, ProductCatalog};
use game_economy::purchase;
use game_economy::reward::{Self, RewardCap, RewardConfig, RewardRegistry};
use game_economy::supply::{Self, CltSpentFlushed, SupplyStats};
use sui::event;
use sui::test_scenario::{Self, Scenario};
use sui::token::{Token, TokenPolicy};

const ADMIN: address = @0xA;
const BACKEND: address = @0xB;
const PLAYER: address = @0xC;
const ATTACKER: address = @0xD;
const PRODUCT_ID: u64 = 42;
const PRICE: u64 = 100;

fun fixed_id(marker: u8): vector<u8> {
    vector[
        marker, marker, marker, marker, marker, marker, marker, marker,
        marker, marker, marker, marker, marker, marker, marker, marker,
        marker, marker, marker, marker, marker, marker, marker, marker,
        marker, marker, marker, marker, marker, marker, marker, marker,
    ]
}

fun initialize(scenario: &mut Scenario) {
    game_credit::init_for_testing(scenario.ctx());
    platform::init_for_testing(scenario.ctx());
    reward::init_for_testing(scenario.ctx());
    product_catalog::init_for_testing(scenario.ctx());
    supply::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::create_product(
        &mut catalog,
        &cap,
        PRODUCT_ID,
        PRICE,
        0,
        0,
    );
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
}

fun initialize_and_delegate(scenario: &mut Scenario) {
    initialize(scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(cap, treasury, BACKEND, scenario.ctx());
    scenario.next_tx(BACKEND);
}

fun reward_player(scenario: &mut Scenario, amount: u64, marker: u8) {
    let cap = scenario.take_from_sender<RewardCap>();
    let mut treasury = scenario.take_from_sender<Treasury>();
    let platform_config = scenario.take_shared<PlatformConfig>();
    let reward_config = scenario.take_shared<RewardConfig>();
    let mut registry = scenario.take_shared<RewardRegistry>();
    reward::reward_player(
        &mut treasury,
        &platform_config,
        &reward_config,
        &mut registry,
        &cap,
        PLAYER,
        amount,
        fixed_id(marker),
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(platform_config);
    test_scenario::return_shared(reward_config);
    test_scenario::return_shared(registry);
}

fun purchase_price(scenario: &mut Scenario, order_marker: u8) {
    let config = scenario.take_shared<PlatformConfig>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let mut token = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let payment = token.split(PRICE, scenario.ctx());
    purchase::purchase_catalog_product(
        &config,
        &mut catalog,
        &mut policy,
        payment,
        PRODUCT_ID,
        fixed_id(order_marker),
        scenario.ctx(),
    );
    scenario.return_to_sender(token);
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
}

fun flush(scenario: &mut Scenario): (u64, u64) {
    let cap = scenario.take_from_sender<RewardCap>();
    let mut treasury = scenario.take_from_sender<Treasury>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let mut stats = scenario.take_shared<SupplyStats>();
    let burned = supply::flush_spent_tokens(
        &mut policy,
        &mut stats,
        &mut treasury,
        &cap,
        scenario.ctx(),
    );
    let supply_after = game_credit::total_supply(&treasury);
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(policy);
    test_scenario::return_shared(stats);
    (burned, supply_after)
}

#[test]
fun supply_accounting_starts_zero() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let stats = scenario.take_shared<SupplyStats>();
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let treasury = scenario.take_from_sender<Treasury>();
    assert_eq!(supply::total_burned(&stats), 0);
    assert_eq!(policy.spent_balance(), 0);
    assert_eq!(game_credit::total_supply(&treasury), 0);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(stats);
    test_scenario::return_shared(policy);
    scenario.end();
}

#[test]
fun purchase_moves_clt_to_spent_balance_without_reducing_supply() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, 1_000, 1);
    scenario.next_tx(PLAYER);
    purchase_price(&mut scenario, 2);
    scenario.next_tx(BACKEND);
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let stats = scenario.take_shared<SupplyStats>();
    let treasury = scenario.take_from_sender<Treasury>();
    assert_eq!(policy.spent_balance(), PRICE);
    assert_eq!(supply::total_burned(&stats), 0);
    assert_eq!(game_credit::total_supply(&treasury), 1_000);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(policy);
    test_scenario::return_shared(stats);
    scenario.end();
}

#[test]
fun authorized_flush_burns_exact_spent_balance_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, 1_000, 3);
    scenario.next_tx(PLAYER);
    purchase_price(&mut scenario, 4);
    scenario.next_tx(BACKEND);
    let (burned, supply_after) = flush(&mut scenario);
    assert_eq!(burned, PRICE);
    assert_eq!(supply_after, 900);

    let events = event::events_by_type<CltSpentFlushed>();
    assert_eq!(events.length(), 1);
    assert_eq!(supply::flushed_amount(&events[0]), PRICE);
    assert_eq!(supply::flushed_total_supply_after(&events[0]), 900);
    assert_eq!(supply::flushed_total_burned(&events[0]), PRICE);

    scenario.next_tx(BACKEND);
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let stats = scenario.take_shared<SupplyStats>();
    assert_eq!(policy.spent_balance(), 0);
    assert_eq!(supply::total_burned(&stats), PRICE);
    test_scenario::return_shared(policy);
    test_scenario::return_shared(stats);
    scenario.end();
}

#[test]
fun lifecycle_remains_usable_after_flush() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, 200, 5);
    scenario.next_tx(PLAYER);
    purchase_price(&mut scenario, 6);
    scenario.next_tx(BACKEND);
    flush(&mut scenario);
    scenario.next_tx(BACKEND);
    reward_player(&mut scenario, 100, 7);
    scenario.next_tx(PLAYER);
    purchase_price(&mut scenario, 8);
    scenario.next_tx(BACKEND);
    let (burned, supply_after) = flush(&mut scenario);
    assert_eq!(burned, PRICE);
    assert_eq!(supply_after, 100);
    scenario.end();
}

#[test, expected_failure(abort_code = supply::ENoSpentTokens, location = supply)]
fun empty_spent_balance_flush_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    flush(&mut scenario);
    scenario.end();
}

#[test, expected_failure(abort_code = test_scenario::EEmptyInventory, location = test_scenario)]
fun unauthorized_account_cannot_obtain_flush_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ATTACKER);
    let cap = scenario.take_from_sender<RewardCap>();
    scenario.return_to_sender(cap);
    scenario.end();
}

#[test]
fun admin_cap_does_not_replace_reward_and_treasury_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    assert!(scenario.has_most_recent_for_sender<AdminCap>());
    assert!(!scenario.has_most_recent_for_sender<RewardCap>());
    assert!(!scenario.has_most_recent_for_sender<Treasury>());
    scenario.end();
}

#[test, expected_failure(abort_code = supply::EBurnAccountingOverflow, location = supply)]
fun burn_accounting_overflow_is_rejected_before_flush() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 9);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let config = scenario.take_shared<PlatformConfig>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    purchase::purchase_catalog_product(
        &config,
        &mut catalog,
        &mut policy,
        payment,
        PRODUCT_ID,
        fixed_id(10),
        scenario.ctx(),
    );
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
    scenario.next_tx(BACKEND);
    let cap = scenario.take_from_sender<RewardCap>();
    let mut treasury = scenario.take_from_sender<Treasury>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let mut stats = scenario.take_shared<SupplyStats>();
    supply::set_total_burned_for_testing(&mut stats, std::u64::max_value!());
    supply::flush_spent_tokens(
        &mut policy,
        &mut stats,
        &mut treasury,
        &cap,
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(policy);
    test_scenario::return_shared(stats);
    scenario.end();
}
