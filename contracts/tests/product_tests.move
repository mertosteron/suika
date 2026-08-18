#[test_only]
module game_economy::product_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::product_catalog::{
    Self,
    ProductCatalog,
    ProductCreated,
    ProductLimitsUpdated,
    ProductPriceUpdated,
    ProductStatusUpdated,
};
use game_economy::purchase;
use game_economy::reward::{Self, RewardCap, RewardConfig, RewardRegistry};
use sui::event;
use sui::test_scenario::{Self, Scenario};
use sui::token::{Token, TokenPolicy};

const ADMIN: address = @0xA;
const BACKEND: address = @0xB;
const PLAYER_ONE: address = @0xC;
const PLAYER_TWO: address = @0xD;
const ATTACKER: address = @0xE;
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
}

fun create_product(
    scenario: &Scenario,
    product_id: u64,
    price: u64,
    sales_limit: u64,
    per_player_limit: u64,
) {
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::create_product(
        &mut catalog,
        &cap,
        product_id,
        price,
        sales_limit,
        per_player_limit,
    );
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
}

fun initialize_with_product(
    scenario: &mut Scenario,
    sales_limit: u64,
    per_player_limit: u64,
) {
    initialize(scenario);
    scenario.next_tx(ADMIN);
    create_product(scenario, PRODUCT_ID, PRICE, sales_limit, per_player_limit);
    scenario.next_tx(ADMIN);
}

fun delegate_reward_authority(scenario: &mut Scenario) {
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(cap, treasury, BACKEND, scenario.ctx());
    scenario.next_tx(BACKEND);
}

fun reward_to(
    scenario: &mut Scenario,
    recipient: address,
    amount: u64,
    marker: u8,
) {
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
        recipient,
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

fun purchase_current_sender(scenario: &mut Scenario, marker: u8) {
    let config = scenario.take_shared<PlatformConfig>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    let mut policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    let payment = scenario.take_from_sender<Token<GAME_CREDIT>>();
    purchase::purchase_catalog_product(
        &config,
        &mut catalog,
        &mut policy,
        payment,
        PRODUCT_ID,
        fixed_id(marker),
        scenario.ctx(),
    );
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
}

#[test]
fun admin_creates_valid_product_and_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    create_product(&scenario, PRODUCT_ID, 275, 10, 3);

    let events = event::events_by_type<ProductCreated>();
    assert_eq!(events.length(), 1);
    assert_eq!(product_catalog::created_product_id(&events[0]), PRODUCT_ID);
    assert_eq!(product_catalog::created_price(&events[0]), 275);
    assert_eq!(product_catalog::created_sales_limit(&events[0]), 10);
    assert_eq!(product_catalog::created_per_player_limit(&events[0]), 3);

    scenario.next_tx(ADMIN);
    let catalog = scenario.take_shared<ProductCatalog>();
    assert!(product_catalog::product_exists_for_testing(&catalog, PRODUCT_ID));
    assert_eq!(product_catalog::product_price(&catalog, PRODUCT_ID), 275);
    assert!(product_catalog::product_active(&catalog, PRODUCT_ID));
    assert_eq!(product_catalog::product_sold_count(&catalog, PRODUCT_ID), 0);
    assert_eq!(product_catalog::product_sales_limit(&catalog, PRODUCT_ID), 10);
    assert_eq!(product_catalog::product_per_player_limit(&catalog, PRODUCT_ID), 3);
    assert_eq!(product_catalog::product_count(&catalog), 1);
    test_scenario::return_shared(catalog);

    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductAlreadyExists, location = product_catalog)]
fun duplicate_product_creation_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    create_product(&scenario, PRODUCT_ID, PRICE, 0, 0);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EInvalidProductPrice, location = product_catalog)]
fun zero_price_product_creation_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    create_product(&scenario, PRODUCT_ID, 0, 0, 0);
    scenario.end();
}

#[test, expected_failure(abort_code = test_scenario::EEmptyInventory, location = test_scenario)]
fun unauthorized_account_cannot_obtain_admin_cap() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ATTACKER);
    let cap = scenario.take_from_sender<AdminCap>();
    scenario.return_to_sender(cap);
    scenario.end();
}

#[test]
fun price_update_preserves_counts_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();

    product_catalog::update_product_price(&mut catalog, &cap, PRODUCT_ID, 150);
    assert_eq!(product_catalog::product_price(&catalog, PRODUCT_ID), 150);
    assert_eq!(product_catalog::product_sold_count(&catalog, PRODUCT_ID), 0);
    let events = event::events_by_type<ProductPriceUpdated>();
    assert_eq!(events.length(), 1);
    assert_eq!(product_catalog::price_updated_old_price(&events[0]), PRICE);
    assert_eq!(product_catalog::price_updated_new_price(&events[0]), 150);

    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EInvalidProductPrice, location = product_catalog)]
fun zero_price_update_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::update_product_price(&mut catalog, &cap, PRODUCT_ID, 0);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductNotFound, location = product_catalog)]
fun unknown_product_update_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::update_product_price(&mut catalog, &cap, 999, 100);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test]
fun disable_and_enable_preserve_history_and_emit_events() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::disable_product(&mut catalog, &cap, PRODUCT_ID);
    assert!(!product_catalog::product_active(&catalog, PRODUCT_ID));
    product_catalog::enable_product(&mut catalog, &cap, PRODUCT_ID);
    assert!(product_catalog::product_active(&catalog, PRODUCT_ID));
    let events = event::events_by_type<ProductStatusUpdated>();
    assert_eq!(events.length(), 2);
    assert!(!product_catalog::status_updated_active(&events[0]));
    assert!(product_catalog::status_updated_active(&events[1]));
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductAlreadyEnabled, location = product_catalog)]
fun repeated_enable_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::enable_product(&mut catalog, &cap, PRODUCT_ID);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EProductAlreadyDisabled, location = product_catalog)]
fun repeated_disable_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::disable_product(&mut catalog, &cap, PRODUCT_ID);
    product_catalog::disable_product(&mut catalog, &cap, PRODUCT_ID);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test]
fun limits_update_without_resetting_counts_and_emit_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 10, 3);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::update_product_limits(&mut catalog, &cap, PRODUCT_ID, 20, 5);
    assert_eq!(product_catalog::product_sales_limit(&catalog, PRODUCT_ID), 20);
    assert_eq!(product_catalog::product_per_player_limit(&catalog, PRODUCT_ID), 5);
    let events = event::events_by_type<ProductLimitsUpdated>();
    assert_eq!(events.length(), 1);
    assert_eq!(product_catalog::limits_updated_old_sales_limit(&events[0]), 10);
    assert_eq!(product_catalog::limits_updated_new_sales_limit(&events[0]), 20);
    assert_eq!(product_catalog::limits_updated_old_per_player_limit(&events[0]), 3);
    assert_eq!(product_catalog::limits_updated_new_per_player_limit(&events[0]), 5);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EGlobalSalesLimitReached, location = product_catalog)]
fun global_sales_limit_cannot_be_bypassed() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 1, 0);
    delegate_reward_authority(&mut scenario);
    reward_to(&mut scenario, PLAYER_ONE, PRICE, 1);
    scenario.next_tx(PLAYER_ONE);
    purchase_current_sender(&mut scenario, 2);
    scenario.next_tx(BACKEND);
    reward_to(&mut scenario, PLAYER_TWO, PRICE, 3);
    scenario.next_tx(PLAYER_TWO);
    purchase_current_sender(&mut scenario, 4);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EPlayerPurchaseLimitReached, location = product_catalog)]
fun per_player_limit_cannot_be_bypassed() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 1);
    delegate_reward_authority(&mut scenario);
    reward_to(&mut scenario, PLAYER_ONE, PRICE, 5);
    scenario.next_tx(PLAYER_ONE);
    purchase_current_sender(&mut scenario, 6);
    scenario.next_tx(BACKEND);
    reward_to(&mut scenario, PLAYER_ONE, PRICE, 7);
    scenario.next_tx(PLAYER_ONE);
    purchase_current_sender(&mut scenario, 8);
    scenario.end();
}

#[test]
fun different_players_have_independent_purchase_counts() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 1);
    delegate_reward_authority(&mut scenario);
    reward_to(&mut scenario, PLAYER_ONE, PRICE, 9);
    scenario.next_tx(BACKEND);
    reward_to(&mut scenario, PLAYER_TWO, PRICE, 10);
    scenario.next_tx(PLAYER_ONE);
    purchase_current_sender(&mut scenario, 11);
    scenario.next_tx(PLAYER_TWO);
    purchase_current_sender(&mut scenario, 12);
    scenario.next_tx(PLAYER_TWO);
    let catalog = scenario.take_shared<ProductCatalog>();
    assert_eq!(product_catalog::product_sold_count(&catalog, PRODUCT_ID), 2);
    assert_eq!(
        product_catalog::player_purchase_count_for_testing(&catalog, PRODUCT_ID, PLAYER_ONE),
        1,
    );
    assert_eq!(
        product_catalog::player_purchase_count_for_testing(&catalog, PRODUCT_ID, PLAYER_TWO),
        1,
    );
    test_scenario::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = product_catalog::EInvalidSalesLimit, location = product_catalog)]
fun sales_limit_cannot_be_lowered_below_sold_count() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_with_product(&mut scenario, 0, 0);
    delegate_reward_authority(&mut scenario);
    reward_to(&mut scenario, PLAYER_ONE, PRICE, 13);
    scenario.next_tx(PLAYER_ONE);
    purchase_current_sender(&mut scenario, 14);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::update_product_limits(&mut catalog, &cap, PRODUCT_ID, 0, 0);
    product_catalog::update_product_limits(&mut catalog, &cap, PRODUCT_ID, 0, 0);
    // A finite zero-below-history case is represented by a sold count of one
    // and a requested finite limit smaller than one. There is no such u64, so
    // create a second sale and request one.
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.next_tx(BACKEND);
    reward_to(&mut scenario, PLAYER_TWO, PRICE, 15);
    scenario.next_tx(PLAYER_TWO);
    purchase_current_sender(&mut scenario, 16);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::update_product_limits(&mut catalog, &cap, PRODUCT_ID, 1, 0);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(catalog);
    scenario.end();
}
