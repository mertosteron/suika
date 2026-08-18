#[test_only]
module game_economy::security_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{
    Self,
    AdminCap,
    AdministrationTransferred,
    PlatformConfig,
};
use game_economy::product_catalog::{Self, ProductCatalog};
use game_economy::purchase;
use game_economy::reward::{Self, RewardCap, RewardConfig, RewardRegistry};
use game_economy::sui_reward::{
    Self,
    SuiRewardCap,
    SuiRewardConfig,
    SuiRewardVault,
};
use game_economy::supply::{Self, SupplyStats};
use sui::balance;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::MetadataCap;
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::token::{Self, Token, TokenPolicy, TokenPolicyCap};

const ADMIN: address = @0xA;
const NEW_ADMIN: address = @0xB;
const CLT_BACKEND: address = @0xC;
const SUI_BACKEND: address = @0xD;
const PLAYER: address = @0xE;
const ATTACKER: address = @0xF;
const PRODUCT_ID: u64 = 42;
const PRICE: u64 = 100;

// Cross-capability substitutions are compile-time failures in Move. Runtime
// tests therefore verify custody separation and valid role effects rather than
// introducing insecure untyped authorization hooks for negative testing.

fun id_with_length(length: u64, marker: u8): vector<u8> {
    let mut id = vector[];
    length.do!(|_| id.push_back(marker));
    id
}

fun fixed_id(marker: u8): vector<u8> {
    id_with_length(32, marker)
}

fun initialize(scenario: &mut Scenario) {
    game_credit::init_for_testing(scenario.ctx());
    platform::init_for_testing(scenario.ctx());
    reward::init_for_testing(scenario.ctx());
    product_catalog::init_for_testing(scenario.ctx());
    supply::init_for_testing(scenario.ctx());
    sui_reward::init_for_testing(scenario.ctx());
}

fun initialize_and_delegate(scenario: &mut Scenario) {
    initialize(scenario);
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut catalog = scenario.take_shared<ProductCatalog>();
    product_catalog::create_product(
        &mut catalog,
        &admin_cap,
        PRODUCT_ID,
        PRICE,
        0,
        0,
    );
    scenario.return_to_sender(admin_cap);
    test_scenario::return_shared(catalog);

    let clt_cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(
        clt_cap,
        treasury,
        CLT_BACKEND,
        scenario.ctx(),
    );
    let sui_cap = scenario.take_from_sender<SuiRewardCap>();
    sui_reward::transfer_sui_reward_authority(
        sui_cap,
        SUI_BACKEND,
        scenario.ctx(),
    );
}

fun reward_clt(
    scenario: &mut Scenario,
    recipient: address,
    amount: u64,
    id: vector<u8>,
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
        id,
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(platform_config);
    test_scenario::return_shared(reward_config);
    test_scenario::return_shared(registry);
}

fun deposit_sui(scenario: &mut Scenario, amount: u64) {
    let payment = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let mut vault = scenario.take_shared<SuiRewardVault>();
    sui_reward::deposit_sui(&mut vault, payment);
    test_scenario::return_shared(vault);
}

fun reward_sui(
    scenario: &mut Scenario,
    recipient: address,
    amount: u64,
    id: vector<u8>,
) {
    let cap = scenario.take_from_sender<SuiRewardCap>();
    let platform_config = scenario.take_shared<PlatformConfig>();
    let reward_config = scenario.take_shared<SuiRewardConfig>();
    let mut vault = scenario.take_shared<SuiRewardVault>();
    sui_reward::reward_player(
        &platform_config,
        &reward_config,
        &mut vault,
        &cap,
        recipient,
        amount,
        id,
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    test_scenario::return_shared(platform_config);
    test_scenario::return_shared(reward_config);
    test_scenario::return_shared(vault);
}

#[test]
fun capability_and_framework_authority_ownership_matches_model() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    assert_eq!(test_scenario::ids_for_address<AdminCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<RewardCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<SuiRewardCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<Treasury>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<AdminCap>(ATTACKER).length(), 0);
    assert_eq!(test_scenario::ids_for_address<RewardCap>(ATTACKER).length(), 0);
    assert_eq!(test_scenario::ids_for_address<SuiRewardCap>(ATTACKER).length(), 0);
    assert_eq!(test_scenario::ids_for_address<TreasuryCap<GAME_CREDIT>>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<TokenPolicyCap<GAME_CREDIT>>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<MetadataCap<GAME_CREDIT>>(ADMIN).length(), 0);

    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    assert!(policy.is_allowed(&token::spend_action()));
    assert!(!policy.is_allowed(&token::transfer_action()));
    assert!(!policy.is_allowed(&token::to_coin_action()));
    assert!(!policy.is_allowed(&token::from_coin_action()));
    test_scenario::return_shared(policy);
    scenario.end();
}

#[test]
fun admin_rotation_moves_only_admin_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    platform::transfer_administration(cap, NEW_ADMIN, scenario.ctx());
    let events = event::events_by_type<AdministrationTransferred>();
    assert_eq!(events.length(), 1);
    assert_eq!(platform::transferred_previous_owner(&events[0]), ADMIN);
    assert_eq!(platform::transferred_new_owner(&events[0]), NEW_ADMIN);
    scenario.next_tx(NEW_ADMIN);
    assert!(scenario.has_most_recent_for_sender<AdminCap>());
    assert!(!scenario.has_most_recent_for_sender<RewardCap>());
    assert!(!scenario.has_most_recent_for_sender<SuiRewardCap>());
    assert!(!scenario.has_most_recent_for_sender<Treasury>());
    scenario.end();
}

#[test]
fun replay_namespaces_are_independent_across_clt_purchase_and_sui() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    let shared_id = fixed_id(1);
    scenario.next_tx(CLT_BACKEND);
    reward_clt(&mut scenario, PLAYER, 200, shared_id);
    scenario.next_tx(SUI_BACKEND);
    deposit_sui(&mut scenario, 1_000);
    scenario.next_tx(SUI_BACKEND);
    reward_sui(&mut scenario, PLAYER, 1_000, shared_id);
    scenario.next_tx(PLAYER);
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
        shared_id,
        scenario.ctx(),
    );
    scenario.return_to_sender(token);
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);

    scenario.next_tx(PLAYER);
    let registry = scenario.take_shared<RewardRegistry>();
    let catalog = scenario.take_shared<ProductCatalog>();
    let vault = scenario.take_shared<SuiRewardVault>();
    assert!(reward::is_processed(&registry, shared_id));
    assert!(product_catalog::order_processed(&catalog, shared_id));
    assert!(sui_reward::is_processed(&vault, shared_id));
    test_scenario::return_shared(registry);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test]
fun clt_minted_minus_flushed_equals_current_supply() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(CLT_BACKEND);
    reward_clt(&mut scenario, PLAYER, 1_000, fixed_id(2));
    scenario.next_tx(PLAYER);
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
        fixed_id(3),
        scenario.ctx(),
    );
    scenario.return_to_sender(token);
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
    scenario.next_tx(CLT_BACKEND);
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
    assert_eq!(burned, PRICE);
    assert_eq!(game_credit::total_supply(&treasury), 1_000 - PRICE);
    assert_eq!(supply::total_burned(&stats), PRICE);
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(policy);
    test_scenario::return_shared(stats);
    scenario.end();
}

#[test, expected_failure(abort_code = platform::EPlatformAlreadyPaused, location = platform)]
fun repeated_global_pause_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<PlatformConfig>();
    platform::pause_platform(&mut config, &cap);
    platform::pause_platform(&mut config, &cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = reward::EInvalidRewardId, location = reward)]
fun clt_reward_id_below_boundary_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(CLT_BACKEND);
    reward_clt(&mut scenario, PLAYER, 1, id_with_length(31, 4));
    scenario.end();
}

#[test, expected_failure(abort_code = purchase::EInvalidOrderId, location = purchase)]
fun purchase_order_id_above_boundary_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(CLT_BACKEND);
    reward_clt(&mut scenario, PLAYER, PRICE, fixed_id(5));
    scenario.next_tx(PLAYER);
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
        id_with_length(33, 6),
        scenario.ctx(),
    );
    test_scenario::return_shared(config);
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(policy);
    scenario.end();
}

#[test, expected_failure(abort_code = balance::EOverflow, location = balance)]
fun clt_supply_overflow_aborts_instead_of_wrapping() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    reward::update_max_reward_per_transaction(
        &mut config,
        &admin_cap,
        std::u64::max_value!(),
    );
    scenario.return_to_sender(admin_cap);
    test_scenario::return_shared(config);
    scenario.next_tx(CLT_BACKEND);
    reward_clt(
        &mut scenario,
        PLAYER,
        std::u64::max_value!(),
        fixed_id(7),
    );
    scenario.next_tx(CLT_BACKEND);
    reward_clt(&mut scenario, ATTACKER, 1, fixed_id(8));
    scenario.end();
}

#[test]
fun sui_reward_changes_only_prefunded_sui_state() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(SUI_BACKEND);
    deposit_sui(&mut scenario, 1_000);
    scenario.next_tx(SUI_BACKEND);
    reward_sui(&mut scenario, PLAYER, 400, fixed_id(9));
    scenario.next_tx(SUI_BACKEND);
    let vault = scenario.take_shared<SuiRewardVault>();
    let treasury = test_scenario::take_from_address<Treasury>(
        &scenario,
        CLT_BACKEND,
    );
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    assert_eq!(sui_reward::balance(&vault), 600);
    assert_eq!(game_credit::total_supply(&treasury), 0);
    assert_eq!(policy.spent_balance(), 0);
    test_scenario::return_shared(vault);
    test_scenario::return_to_address(CLT_BACKEND, treasury);
    test_scenario::return_shared(policy);
    scenario.next_tx(PLAYER);
    let payout = scenario.take_from_sender<Coin<SUI>>();
    assert_eq!(payout.value(), 400);
    assert_eq!(test_scenario::ids_for_address<Token<GAME_CREDIT>>(PLAYER).length(), 0);
    scenario.return_to_sender(payout);
    scenario.end();
}
