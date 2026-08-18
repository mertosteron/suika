#[test_only]
module game_economy::clt_reward_tests;

use std::unit_test::assert_eq;
use game_economy::game_credit::{Self, GAME_CREDIT, Treasury};
use game_economy::platform::{Self, AdminCap, PlatformConfig};
use game_economy::reward::{
    Self,
    CltRewarded,
    CltRewardsPauseChanged,
    MaxCltRewardChanged,
    RewardAuthorityTransferred,
    RewardCap,
    RewardConfig,
    RewardRegistry,
};
use sui::event;
use sui::test_scenario::{Self, Scenario};
use sui::token::Token;

const ADMIN: address = @0xA;
const BACKEND: address = @0xB;
const PLAYER_ONE: address = @0xC;
const PLAYER_TWO: address = @0xD;
const ATTACKER: address = @0xE;

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
}

fun initialize_and_delegate(scenario: &mut Scenario) {
    initialize(scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(cap, treasury, BACKEND, scenario.ctx());
    scenario.next_tx(BACKEND);
}

fun execute_reward(
    scenario: &mut Scenario,
    recipient: address,
    amount: u64,
    reward_id: vector<u8>,
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
        reward_id,
        scenario.ctx(),
    );
    scenario.return_to_sender(cap);
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(platform_config);
    test_scenario::return_shared(reward_config);
    test_scenario::return_shared(registry);
}

fun set_reward_pause(scenario: &mut Scenario, paused: bool) {
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    if (paused) {
        reward::pause_clt_rewards(&mut config, &cap);
    } else {
        reward::unpause_clt_rewards(&mut config, &cap);
    };
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(BACKEND);
}

#[test]
fun initialization_creates_reward_cap_config_and_registry() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);

    assert_eq!(test_scenario::ids_for_address<RewardCap>(ADMIN).length(), 1);
    let config = scenario.take_shared<RewardConfig>();
    let registry = scenario.take_shared<RewardRegistry>();
    assert!(!reward::rewards_paused(&config));
    assert_eq!(
        reward::max_reward_per_transaction(&config),
        reward::initial_max_reward_per_transaction(),
    );
    assert_eq!(reward::reward_id_length(), 32);
    assert_eq!(reward::processed_count(&registry), 0);
    test_scenario::return_shared(config);
    test_scenario::return_shared(registry);

    scenario.end();
}

#[test]
fun authority_handoff_moves_cap_and_treasury_together() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<RewardCap>();
    let treasury = scenario.take_from_sender<Treasury>();
    reward::transfer_reward_authority(cap, treasury, BACKEND, scenario.ctx());

    let events = event::events_by_type<RewardAuthorityTransferred>();
    assert_eq!(events.length(), 1);
    assert_eq!(reward::authority_previous_owner(&events[0]), ADMIN);
    assert_eq!(reward::authority_new_owner(&events[0]), BACKEND);

    scenario.next_tx(BACKEND);
    assert_eq!(test_scenario::ids_for_address<RewardCap>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<Treasury>(ADMIN).length(), 0);
    assert_eq!(test_scenario::ids_for_address<RewardCap>(BACKEND).length(), 1);
    assert_eq!(test_scenario::ids_for_address<Treasury>(BACKEND).length(), 1);
    scenario.end();
}

#[test]
fun authorized_reward_mints_exact_clt_records_replay_and_emits_event() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    let id = fixed_id(1);
    execute_reward(&mut scenario, PLAYER_ONE, 12_345, id);

    let events = event::events_by_type<CltRewarded>();
    assert_eq!(events.length(), 1);
    assert_eq!(reward::rewarded_recipient(&events[0]), PLAYER_ONE);
    assert_eq!(reward::rewarded_amount(&events[0]), 12_345);
    assert_eq!(reward::rewarded_id(&events[0]), id);

    scenario.next_tx(BACKEND);
    let treasury = scenario.take_from_sender<Treasury>();
    let registry = scenario.take_shared<RewardRegistry>();
    assert_eq!(game_credit::total_supply(&treasury), 12_345);
    assert_eq!(reward::processed_count(&registry), 1);
    assert!(reward::is_processed(&registry, id));
    scenario.return_to_sender(treasury);
    test_scenario::return_shared(registry);

    scenario.next_tx(PLAYER_ONE);
    let token = scenario.take_from_sender<Token<GAME_CREDIT>>();
    assert_eq!(token.value(), 12_345);
    scenario.return_to_sender(token);

    scenario.end();
}

#[test]
fun different_players_receive_only_their_rewards() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    execute_reward(&mut scenario, PLAYER_ONE, 700, fixed_id(2));
    scenario.next_tx(BACKEND);
    execute_reward(&mut scenario, PLAYER_TWO, 900, fixed_id(3));

    scenario.next_tx(PLAYER_ONE);
    let first = scenario.take_from_sender<Token<GAME_CREDIT>>();
    let second = test_scenario::take_from_address<Token<GAME_CREDIT>>(
        &scenario,
        PLAYER_TWO,
    );
    assert_eq!(first.value(), 700);
    assert_eq!(second.value(), 900);
    scenario.return_to_sender(first);
    test_scenario::return_to_address(PLAYER_TWO, second);

    scenario.end();
}

#[test, expected_failure(abort_code = test_scenario::EEmptyInventory, location = test_scenario)]
fun unauthorized_account_cannot_obtain_reward_cap() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ATTACKER);
    let cap = scenario.take_from_sender<RewardCap>();
    scenario.return_to_sender(cap);
    scenario.end();
}

#[test]
fun admin_cap_does_not_grant_clt_treasury_authority() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);

    assert!(scenario.has_most_recent_for_sender<AdminCap>());
    assert!(!scenario.has_most_recent_for_sender<RewardCap>());
    assert!(!scenario.has_most_recent_for_sender<Treasury>());

    scenario.end();
}

#[test, expected_failure(abort_code = reward::EZeroRewardAmount, location = reward)]
fun zero_reward_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    execute_reward(&mut scenario, PLAYER_ONE, 0, fixed_id(4));
    scenario.end();
}

#[test, expected_failure(abort_code = reward::ERewardTooLarge, location = reward)]
fun reward_above_maximum_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    execute_reward(
        &mut scenario,
        PLAYER_ONE,
        reward::initial_max_reward_per_transaction() + 1,
        fixed_id(5),
    );
    scenario.end();
}

#[test, expected_failure(abort_code = reward::EInvalidRewardId, location = reward)]
fun invalid_reward_id_length_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    execute_reward(&mut scenario, PLAYER_ONE, 1, vector[1, 2, 3]);
    scenario.end();
}

#[test, expected_failure(abort_code = reward::ERewardAlreadyProcessed, location = reward)]
fun duplicate_reward_id_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    execute_reward(&mut scenario, PLAYER_ONE, 100, fixed_id(6));
    scenario.next_tx(BACKEND);
    execute_reward(&mut scenario, PLAYER_TWO, 200, fixed_id(6));
    scenario.end();
}

#[test, expected_failure(abort_code = reward::ERewardsPaused, location = reward)]
fun clt_reward_pause_blocks_reward() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    set_reward_pause(&mut scenario, true);
    execute_reward(&mut scenario, PLAYER_ONE, 100, fixed_id(7));
    scenario.end();
}

#[test, expected_failure(abort_code = reward::EPlatformPaused, location = reward)]
fun global_pause_blocks_reward() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<PlatformConfig>();
    platform::pause_platform(&mut config, &cap);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(BACKEND);
    execute_reward(&mut scenario, PLAYER_ONE, 100, fixed_id(8));
    scenario.end();
}

#[test]
fun reward_pause_can_be_removed_and_emits_state_changes() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    reward::pause_clt_rewards(&mut config, &cap);
    reward::unpause_clt_rewards(&mut config, &cap);

    let events = event::events_by_type<CltRewardsPauseChanged>();
    assert_eq!(events.length(), 2);
    assert!(reward::pause_changed_value(&events[0]));
    assert!(!reward::pause_changed_value(&events[1]));
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);

    scenario.next_tx(BACKEND);
    execute_reward(&mut scenario, PLAYER_ONE, 222, fixed_id(9));

    scenario.end();
}

#[test]
fun admin_updates_maximum_and_event_reports_limits() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    let old_limit = reward::max_reward_per_transaction(&config);

    reward::update_max_reward_per_transaction(&mut config, &cap, 750);
    assert_eq!(reward::max_reward_per_transaction(&config), 750);
    let events = event::events_by_type<MaxCltRewardChanged>();
    assert_eq!(events.length(), 1);
    assert_eq!(reward::max_changed_old_limit(&events[0]), old_limit);
    assert_eq!(reward::max_changed_new_limit(&events[0]), 750);

    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = reward::EInvalidMaxReward, location = reward)]
fun zero_maximum_is_rejected() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    reward::update_max_reward_per_transaction(&mut config, &cap, 0);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
fun exact_updated_maximum_succeeds() {
    let mut scenario = test_scenario::begin(ADMIN);
    initialize_and_delegate(&mut scenario);
    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<RewardConfig>();
    reward::update_max_reward_per_transaction(&mut config, &cap, 750);
    scenario.return_to_sender(cap);
    test_scenario::return_shared(config);
    scenario.next_tx(BACKEND);
    execute_reward(&mut scenario, PLAYER_ONE, 750, fixed_id(10));
    scenario.next_tx(PLAYER_ONE);
    let token = scenario.take_from_sender<Token<GAME_CREDIT>>();
    assert_eq!(token.value(), 750);
    scenario.return_to_sender(token);
    scenario.end();
}
