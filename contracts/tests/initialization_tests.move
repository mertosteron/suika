#[test_only]
module game_economy::initialization_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::product_catalog::{Self, ProductCatalog};
use game_economy::reward::{Self, RewardCap, RewardConfig, RewardRegistry};
use game_economy::sui_reward::{
    Self,
    SuiRewardCap,
    SuiRewardConfig,
    SuiRewardVault,
};
use game_economy::supply::{Self, SupplyStats};
use sui::coin::{Coin, TreasuryCap};
use sui::coin_registry::{Currency, MetadataCap};
use sui::test_scenario::{Self, Scenario};
use sui::token::{Self, Token, TokenPolicy, TokenPolicyCap};

const ADMIN: address = @0xA11CE;
const PLAYER: address = @0xB0B;
const COIN_REGISTRY_ADDRESS: address = @0xC;

fun initialize(scenario: &mut Scenario) {
    game_credit::init_for_testing(scenario.ctx());
    platform::init_for_testing(scenario.ctx());
    reward::init_for_testing(scenario.ctx());
    product_catalog::init_for_testing(scenario.ctx());
    supply::init_for_testing(scenario.ctx());
    sui_reward::init_for_testing(scenario.ctx());
}

#[test]
fun package_initializes_expected_capabilities_and_state() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    assert_eq!(test_scenario::ids_for_address<AdminCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<RewardCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<SuiRewardCap>(ADMIN).length(), 1);
    assert_eq!(test_scenario::ids_for_address<Treasury>(ADMIN).length(), 1);
    assert!(test_scenario::has_most_recent_shared<PlatformConfig>());
    assert!(test_scenario::has_most_recent_shared<TokenPolicy<GAME_CREDIT>>());
    assert!(test_scenario::has_most_recent_shared<RewardConfig>());
    assert!(test_scenario::has_most_recent_shared<RewardRegistry>());
    assert!(test_scenario::has_most_recent_shared<ProductCatalog>());
    assert!(test_scenario::has_most_recent_shared<SupplyStats>());
    assert!(test_scenario::has_most_recent_shared<SuiRewardConfig>());
    assert!(test_scenario::has_most_recent_shared<SuiRewardVault>());

    scenario.end();
}

#[test]
fun platform_configuration_starts_active() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    let config = scenario.take_shared<PlatformConfig>();
    assert!(!platform::paused(&config));
    assert!(!platform::clt_spending_paused(&config));
    test_scenario::return_shared(config);

    scenario.end();
}

#[test]
fun treasury_is_owned_and_framework_authorities_are_not_exposed() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    assert!(!test_scenario::has_most_recent_shared<Treasury>());
    let treasury = scenario.take_from_sender<Treasury>();
    assert_eq!(game_credit::total_supply(&treasury), 0);
    scenario.return_to_sender(treasury);

    assert_eq!(
        test_scenario::ids_for_address<TreasuryCap<GAME_CREDIT>>(ADMIN).length(),
        0,
    );
    assert_eq!(
        test_scenario::ids_for_address<TokenPolicyCap<GAME_CREDIT>>(ADMIN)
            .length(),
        0,
    );
    assert_eq!(
        test_scenario::ids_for_address<MetadataCap<GAME_CREDIT>>(ADMIN).length(),
        0,
    );

    scenario.end();
}

#[test]
fun token_policy_allows_only_rule_gated_spending() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    assert!(!policy.is_allowed(&token::transfer_action()));
    assert!(policy.is_allowed(&token::spend_action()));
    assert_eq!(policy.rules(&token::spend_action()).length(), 1);
    assert!(!policy.is_allowed(&token::to_coin_action()));
    assert!(!policy.is_allowed(&token::from_coin_action()));
    assert_eq!(policy.spent_balance(), 0);
    test_scenario::return_shared(policy);

    scenario.end();
}

#[test]
fun currency_metadata_is_final_and_matches_branding() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    let currency = test_scenario::take_from_address<Currency<GAME_CREDIT>>(
        &scenario,
        COIN_REGISTRY_ADDRESS,
    );
    assert_eq!(currency.decimals(), 2);
    assert_eq!(currency.symbol(), b"M".to_string());
    assert_eq!(currency.name(), b"Mola Token".to_string());
    assert_eq!(
        currency.description(),
        b"Closed-loop utility token for the game economy".to_string(),
    );
    assert_eq!(currency.icon_url(), b"".to_string());
    assert!(!currency.is_regulated());
    assert!(currency.total_supply().is_none());
    assert!(currency.is_metadata_cap_deleted());
    test_scenario::return_to_address(COIN_REGISTRY_ADDRESS, currency);

    scenario.end();
}

#[test]
fun initialization_mints_no_clt() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(PLAYER);

    assert_eq!(test_scenario::ids_for_address<Token<GAME_CREDIT>>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<Token<GAME_CREDIT>>(PLAYER).length(), 0);
    assert_eq!(test_scenario::ids_for_address<Coin<GAME_CREDIT>>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<Coin<GAME_CREDIT>>(PLAYER).length(), 0);

    scenario.end();
}

#[test]
fun catalogs_replay_sets_supply_and_vault_start_empty() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    let catalog = scenario.take_shared<ProductCatalog>();
    let registry = scenario.take_shared<RewardRegistry>();
    let stats = scenario.take_shared<SupplyStats>();
    let vault = scenario.take_shared<SuiRewardVault>();
    let clt_config = scenario.take_shared<RewardConfig>();
    let sui_config = scenario.take_shared<SuiRewardConfig>();
    assert_eq!(product_catalog::product_count(&catalog), 0);
    assert_eq!(product_catalog::processed_order_count(&catalog), 0);
    assert_eq!(reward::processed_count(&registry), 0);
    assert_eq!(supply::total_burned(&stats), 0);
    assert_eq!(sui_reward::balance(&vault), 0);
    assert_eq!(sui_reward::processed_count(&vault), 0);
    assert!(!reward::rewards_paused(&clt_config));
    assert!(!sui_reward::rewards_paused(&sui_config));
    test_scenario::return_shared(catalog);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(stats);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(clt_config);
    test_scenario::return_shared(sui_config);

    scenario.end();
}

#[test]
fun ordinary_player_receives_no_privileged_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(PLAYER);

    assert!(!scenario.has_most_recent_for_sender<AdminCap>());
    assert!(!scenario.has_most_recent_for_sender<RewardCap>());
    assert!(!scenario.has_most_recent_for_sender<SuiRewardCap>());
    assert!(!scenario.has_most_recent_for_sender<Treasury>());
    assert!(test_scenario::ids_for_address<AdminCap>(ADMIN).length() == 1);

    scenario.end();
}
