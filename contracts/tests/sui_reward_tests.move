#[test_only]
module game_economy::sui_reward_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::reward::{Self, RewardCap};
use game_economy::sui_reward::{
    Self,
    MaxSuiRewardChanged,
    SuiRewardAuthorityTransferred,
    SuiRewardCap,
    SuiRewardConfig,
    SuiRewardVault,
    SuiRewarded,
    SuiRewardsPauseChanged,
    SuiVaultFunded,
};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::token::{Token, TokenPolicy};

const ADMIN: address = @0xA;
const SUI_BACKEND: address = @0xB;
const CLT_BACKEND: address = @0xC;
const PLAYER_ONE: address = @0xD;
const PLAYER_TWO: address = @0xE;
const ATTACKER: address = @0xF;

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
    sui_reward::init_for_testing(scenario.ctx());
}

fun initialize_and_delegate(scenario: &mut Scenario) {
    initialize(scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<SuiRewardCap>();
    sui_reward::transfer_sui_reward_authority(cap, SUI_BACKEND, scenario.ctx());
    scenario.next_tx(SUI_BACKEND);
}

fun deposit(scenario: &mut Scenario, amount: u64) {
    let payment = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let mut vault = scenario.take_shared<SuiRewardVault>();
    sui_reward::deposit_sui(&mut vault, payment);
    test_scenario::return_shared(vault);
}

fun reward_player(
    scenario: &mut Scenario,
    recipient: address,
    amount: u64,
    reward_id: vector<u8>,
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
        reward_id,
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    test_scenario::return_shared(platform_config);
    test_scenario::return_shared(reward_config);
    test_scenario::return_shared(vault);
}

fun set_reward_pause(scenario: &mut Scenario, paused: bool) {
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<SuiRewardConfig>();
    if (paused) {
        sui_reward::pause_sui_rewards(&mut config, &cap);
    } else {
        sui_reward::unpause_sui_rewards(&mut config, &cap);
    };
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(SUI_BACKEND);
}

#[test]
fun initialization_creates_dedicated_cap_config_and_empty_vault() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    assert_eq!(test_scenario::ids_for_address<SuiRewardCap>(ADMIN).length(), 1);
    let config = scenario.take_shared<SuiRewardConfig>();
    let vault = scenario.take_shared<SuiRewardVault>();
    assert!(!sui_reward::rewards_paused(&config));
    assert_eq!(
        sui_reward::max_reward_per_transaction(&config),
        sui_reward::initial_max_reward_per_transaction(),
    );
    assert_eq!(sui_reward::balance(&vault), 0);
    assert_eq!(sui_reward::processed_count(&vault), 0);
    test_scenario::return_shared(config);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test]
fun permissionless_funding_increases_vault_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ATTACKER);
    deposit(&mut scenario, 250_000_000);

    let events = event::events_by_type<SuiVaultFunded>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui_reward::funded_amount(&events[0]), 250_000_000);
    assert_eq!(sui_reward::funded_balance_after(&events[0]), 250_000_000);
    scenario.next_tx(ATTACKER);
    let vault = scenario.take_shared<SuiRewardVault>();
    assert_eq!(sui_reward::balance(&vault), 250_000_000);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test]
fun multiple_funders_accumulate_without_receiving_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100_000_000);
    scenario.next_tx(ATTACKER);
    deposit(&mut scenario, 350_000_000);
    scenario.next_tx(ATTACKER);
    let vault = scenario.take_shared<SuiRewardVault>();
    assert_eq!(sui_reward::balance(&vault), 450_000_000);
    test_scenario::return_shared(vault);
    assert!(!scenario.has_most_recent_for_sender<SuiRewardCap>());
    assert_eq!(test_scenario::ids_for_address<SuiRewardCap>(SUI_BACKEND).length(), 1);
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EZeroDeposit, location = sui_reward)]
fun zero_funding_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ATTACKER);
    let payment = coin::zero<SUI>(scenario.ctx());
    let mut vault = scenario.take_shared<SuiRewardVault>();
    sui_reward::deposit_sui(&mut vault, payment);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test]
fun authorized_reward_pays_exact_sui_updates_vault_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 2_000_000_000);
    scenario.next_tx(SUI_BACKEND);
    let id = fixed_id(1);
    reward_player(&mut scenario, PLAYER_ONE, 750_000_000, id);

    let events = event::events_by_type<SuiRewarded>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui_reward::rewarded_recipient(&events[0]), PLAYER_ONE);
    assert_eq!(sui_reward::rewarded_amount(&events[0]), 750_000_000);
    assert_eq!(sui_reward::rewarded_id(&events[0]), id);

    scenario.next_tx(SUI_BACKEND);
    let vault = scenario.take_shared<SuiRewardVault>();
    assert_eq!(sui_reward::balance(&vault), 1_250_000_000);
    assert_eq!(sui_reward::processed_count(&vault), 1);
    assert!(sui_reward::is_processed(&vault, id));
    test_scenario::return_shared(vault);
    scenario.next_tx(PLAYER_ONE);
    let payout = scenario.take_from_sender<Coin<SUI>>();
    assert_eq!(payout.value(), 750_000_000);
    scenario.return_to_sender(payout);
    scenario.end();
}

#[test]
fun reward_equal_to_vault_balance_empties_vault() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 300_000_000);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 300_000_000, fixed_id(2));
    scenario.next_tx(SUI_BACKEND);
    let vault = scenario.take_shared<SuiRewardVault>();
    assert_eq!(sui_reward::balance(&vault), 0);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EZeroRewardAmount, location = sui_reward)]
fun zero_reward_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 1);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 0, fixed_id(3));
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::ERewardTooLarge, location = sui_reward)]
fun reward_above_configured_maximum_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<SuiRewardConfig>();
    sui_reward::update_max_reward_per_transaction(&mut config, &cap, 500);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(SUI_BACKEND);
    deposit(&mut scenario, 1_000);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 501, fixed_id(4));
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EInsufficientVaultBalance, location = sui_reward)]
fun insufficient_vault_balance_is_rejected_before_replay_registration() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 101, fixed_id(5));
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EInvalidRewardId, location = sui_reward)]
fun invalid_reward_id_length_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 100, vector[1, 2]);
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::ERewardAlreadyProcessed, location = sui_reward)]
fun duplicate_reward_id_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 200);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 100, fixed_id(6));
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_TWO, 100, fixed_id(6));
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::ERewardsPaused, location = sui_reward)]
fun dedicated_pause_blocks_sui_reward() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100);
    set_reward_pause(&mut scenario, true);
    reward_player(&mut scenario, PLAYER_ONE, 100, fixed_id(7));
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EPlatformPaused, location = sui_reward)]
fun global_pause_blocks_sui_reward() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<PlatformConfig>();
    platform::pause_platform(&mut config, &cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 100, fixed_id(8));
    scenario.end();
}

#[test]
fun pause_can_be_removed_and_events_report_state() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 100);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<SuiRewardConfig>();
    sui_reward::pause_sui_rewards(&mut config, &cap);
    sui_reward::unpause_sui_rewards(&mut config, &cap);
    let events = event::events_by_type<SuiRewardsPauseChanged>();
    assert_eq!(events.length(), 2);
    assert!(sui_reward::pause_changed_value(&events[0]));
    assert!(!sui_reward::pause_changed_value(&events[1]));
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 100, fixed_id(9));
    scenario.end();
}

#[test]
fun admin_updates_maximum_and_event_reports_limits() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<SuiRewardConfig>();
    let old_limit = sui_reward::max_reward_per_transaction(&config);
    sui_reward::update_max_reward_per_transaction(&mut config, &cap, 2_000);
    let events = event::events_by_type<MaxSuiRewardChanged>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui_reward::max_changed_old_limit(&events[0]), old_limit);
    assert_eq!(sui_reward::max_changed_new_limit(&events[0]), 2_000);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = sui_reward::EInvalidMaxReward, location = sui_reward)]
fun zero_maximum_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<SuiRewardConfig>();
    sui_reward::update_max_reward_per_transaction(&mut config, &cap, 0);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = test_scenario::EEmptyInventory, location = test_scenario)]
fun unauthorized_account_cannot_obtain_sui_reward_cap() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ATTACKER);
    let cap = scenario.take_from_sender<SuiRewardCap>();
    scenario.return_to_sender(cap);
    scenario.end();
}

#[test]
fun reward_capabilities_are_independent() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let sui_cap = scenario.take_from_sender<SuiRewardCap>();
    sui_reward::transfer_sui_reward_authority(sui_cap, SUI_BACKEND, scenario.ctx());
    let clt_cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(clt_cap, treasury, CLT_BACKEND, scenario.ctx());
    scenario.next_tx(CLT_BACKEND);
    assert!(scenario.has_most_recent_for_sender<RewardCap>());
    assert!(scenario.has_most_recent_for_sender<Treasury>());
    assert!(!scenario.has_most_recent_for_sender<SuiRewardCap>());
    scenario.next_tx(SUI_BACKEND);
    assert!(scenario.has_most_recent_for_sender<SuiRewardCap>());
    assert!(!scenario.has_most_recent_for_sender<RewardCap>());
    assert!(!scenario.has_most_recent_for_sender<Treasury>());
    scenario.end();
}

#[test]
fun sui_reward_does_not_change_clt_supply_or_spent_balance() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    deposit(&mut scenario, 1_000);
    scenario.next_tx(SUI_BACKEND);
    reward_player(&mut scenario, PLAYER_ONE, 1_000, fixed_id(10));
    scenario.next_tx(SUI_BACKEND);
    let treasury = test_scenario::take_from_address<Treasury>(&scenario, ADMIN);
    let policy = scenario.take_shared<TokenPolicy<GAME_CREDIT>>();
    assert_eq!(game_credit::total_supply(&treasury), 0);
    assert_eq!(policy.spent_balance(), 0);
    test_scenario::return_to_address(ADMIN, treasury);
    test_scenario::return_shared(policy);
    scenario.next_tx(PLAYER_ONE);
    assert_eq!(test_scenario::ids_for_address<Coin<SUI>>(PLAYER_ONE).length(), 1);
    assert_eq!(test_scenario::ids_for_address<Token<GAME_CREDIT>>(PLAYER_ONE).length(), 0);
    scenario.end();
}

#[test]
fun sui_reward_authority_rotation_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<SuiRewardCap>();
    sui_reward::transfer_sui_reward_authority(cap, SUI_BACKEND, scenario.ctx());
    let events = event::events_by_type<SuiRewardAuthorityTransferred>();
    assert_eq!(events.length(), 1);
    assert_eq!(sui_reward::authority_previous_owner(&events[0]), ADMIN);
    assert_eq!(sui_reward::authority_new_owner(&events[0]), SUI_BACKEND);
    scenario.end();
}
