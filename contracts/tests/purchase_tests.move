#[test_only]
module game_economy::purchase_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::product_catalog::{Self, ProductCatalog};
use game_economy::purchase::{Self, PurchaseCompleted};
use game_economy::reward::{Self, RewardCap, RewardConfig, RewardRegistry};
use sui::event;
use sui::object;
use sui::test_scenario::{Self, Scenario};
use sui::token::{Self, Token, TokenPolicy};

const ADMIN: address = @0xA;
const BACKEND: address = @0xB;
const PLAYER: address = @0xC;
const PRODUCT_ID: u64 = 42;
const PRICE: u64 = 100;

public struct FakePurchaseRule has drop {}

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

fun purchase(
    scenario: &mut Scenario,
    payment: Token<GAME_CREDIT>,
    product_id: u64,
    order_id: vector<u8>,
) {
    let config = scenario.take_shared<PlatformConfig>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    purchase::purchase_catalog_product(
        &config,
        &mut catalog,
        &mut policy,
        payment,
        product_id,
        order_id,
        scenario.ctx(),
    );
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
}

#[test]
fun exact_price_purchase_consumes_payment_updates_counts_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, 1_000, 1);
    scenario.next_tx(PLAYER);

    let mut token = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let payment = token.split(PRICE, scenario.ctx());
    let payment_id = object::id(&payment);
    let order_id = fixed_id(2);
    purchase(&mut scenario, payment, PRODUCT_ID, order_id);
    scenario.return_to_sender(token);

    let events = event::events_by_type<PurchaseCompleted>();
    assert_eq!(events.length(), 1);
    assert_eq!(purchase::completed_buyer(&events[0]), PLAYER);
    assert_eq!(purchase::completed_product_id(&events[0]), PRODUCT_ID);
    assert_eq!(purchase::completed_amount(&events[0]), PRICE);
    assert_eq!(purchase::completed_order_id(&events[0]), order_id);

    scenario.next_tx(PLAYER);
    let catalog = scenario.take_shared<ProductCatalog>();
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    assert_eq!(policy.spent_balance(), PRICE);
    assert_eq!(product_catalog::product_sold_count(&catalog, PRODUCT_ID), 1);
    assert_eq!(
        product_catalog::player_purchase_count_for_testing(&catalog, PRODUCT_ID, PLAYER),
        1,
    );
    assert_eq!(product_catalog::processed_order_count(&catalog), 1);
    assert!(product_catalog::order_processed(&catalog, order_id));
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
    let remaining = scenario.take_from_sender<Token<GAME_CREDIT>>();
    assert_eq!(remaining.value(), 900);
    assert!(!test_scenario::ids_for_address<Token<GAME_CREDIT>>(PLAYER)
        .contains(&payment_id));
    scenario.return_to_sender(remaining);
    scenario.end();
}

#[test]
fun whole_token_exact_price_purchase_succeeds() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 3);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(4));
    scenario.next_tx(PLAYER);
    assert_eq!(test_scenario::ids_for_address<Token<GAME_CREDIT>>(PLAYER).length(), 0);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductNotFound, location = product_catalog)]
fun unknown_product_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 5);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, 999, fixed_id(6));
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductInactive, location = product_catalog)]
fun disabled_product_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 7);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::disable_product(&mut catalog, &cap, PRODUCT_ID);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(8));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EInvalidPaymentAmount, location = purchase)]
fun underpayment_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 9);
    scenario.next_tx(PLAYER);
    let mut token = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let payment = token.split(PRICE - 1, scenario.ctx());
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(10));
    scenario.return_to_sender(token);
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EInvalidPaymentAmount, location = purchase)]
fun overpayment_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE + 1, 11);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(12));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EZeroPayment, location = purchase)]
fun zero_payment_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(PLAYER);
    let payment = token::zero<GAME_CREDIT>(scenario.ctx());
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(13));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EInvalidOrderId, location = purchase)]
fun invalid_order_id_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 14);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, vector[1, 2]);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EPurchaseAlreadyProcessed, location = product_catalog)]
fun reused_order_id_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 15);
    scenario.next_tx(PLAYER);
    let first = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, first, PRODUCT_ID, fixed_id(16));
    scenario.next_tx(BACKEND);
    reward_player(&mut scenario, PRICE, 17);
    scenario.next_tx(PLAYER);
    let second = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, second, PRODUCT_ID, fixed_id(16));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EPlatformPaused, location = purchase)]
fun global_pause_blocks_purchase() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 18);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<PlatformConfig>();
    platform::pause_platform(&mut config, &cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(19));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::ECltSpendingPaused, location = purchase)]
fun clt_spending_pause_blocks_purchase() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 20);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<PlatformConfig>();
    platform::pause_clt_spending(&mut config, &cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(PLAYER);
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase(&mut scenario, payment, PRODUCT_ID, fixed_id(21));
    scenario.end();
}

#[test, expected_failure(abort_code = token::ENotApproved, location = token)]
fun raw_spend_request_cannot_bypass_purchase_rule() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 22);
    scenario.next_tx(PLAYER);
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let request = payment.spend(scenario.ctx());
    policy.confirm_request_mut(request, scenario.ctx());
    test_scenario::return_shared(policy);
    scenario.end();
}

#[test, expected_failure(abort_code = token::ENotApproved, location = token)]
fun forged_rule_type_cannot_bypass_purchase_rule() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    reward_player(&mut scenario, PRICE, 23);
    scenario.next_tx(PLAYER);
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let mut request = payment.spend(scenario.ctx());
    token::add_approval(FakePurchaseRule {}, &mut request, scenario.ctx());
    policy.confirm_request_mut(request, scenario.ctx());
    test_scenario::return_shared(policy);
    scenario.end();
}
