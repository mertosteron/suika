module game_economy::platform;

use sui::event;

const EPlatformAlreadyPaused: u64 = 0;
const EPlatformNotPaused: u64 = 1;
const ECltSpendingAlreadyPaused: u64 = 2;
const ECltSpendingNotPaused: u64 = 3;

/// Administrative authority for platform controls, reward configuration, and
/// product administration. It does not grant CLT treasury or SUI vault access.
///
/// `key` without `store` prevents generic transfer, wrapping, sharing, copying,
/// or dropping. Custody can move only through `transfer_administration`.
public struct AdminCap has key {
    id: UID,
}

/// Global controls shared by every player-facing economic transaction.
public struct PlatformConfig has key {
    id: UID,
    paused: bool,
    clt_spending_paused: bool,
}

public struct PlatformPauseChanged has copy, drop {
    paused: bool,
}

public struct CltSpendingPauseChanged has copy, drop {
    paused: bool,
}

public struct AdministrationTransferred has copy, drop {
    previous_owner: address,
    new_owner: address,
}

fun init(ctx: &mut TxContext) {
    let administrator = ctx.sender();
    transfer::transfer(
        AdminCap { id: object::new(ctx) },
        administrator,
    );
    transfer::share_object(PlatformConfig {
        id: object::new(ctx),
        paused: false,
        clt_spending_paused: false,
    });
}

/// Moves the key-only administrative capability to new custody.
public fun transfer_administration(
    admin_cap: AdminCap,
    recipient: address,
    ctx: &mut TxContext,
) {
    let previous_owner = ctx.sender();
    transfer::transfer(admin_cap, recipient);
    event::emit(AdministrationTransferred {
        previous_owner,
        new_owner: recipient,
    });
}

/// Stops CLT rewards, CLT purchases, and SUI rewards.
public fun pause_platform(config: &mut PlatformConfig, _admin_cap: &AdminCap) {
    assert!(!config.paused, EPlatformAlreadyPaused);
    config.paused = true;
    event::emit(PlatformPauseChanged { paused: true });
}

/// Restores all flows after a global pause.
public fun unpause_platform(config: &mut PlatformConfig, _admin_cap: &AdminCap) {
    assert!(config.paused, EPlatformNotPaused);
    config.paused = false;
    event::emit(PlatformPauseChanged { paused: false });
}

public fun pause_clt_spending(
    config: &mut PlatformConfig,
    _admin_cap: &AdminCap,
) {
    assert!(!config.clt_spending_paused, ECltSpendingAlreadyPaused);
    config.clt_spending_paused = true;
    event::emit(CltSpendingPauseChanged { paused: true });
}

public fun unpause_clt_spending(
    config: &mut PlatformConfig,
    _admin_cap: &AdminCap,
) {
    assert!(config.clt_spending_paused, ECltSpendingNotPaused);
    config.clt_spending_paused = false;
    event::emit(CltSpendingPauseChanged { paused: false });
}

public(package) fun paused(config: &PlatformConfig): bool {
    config.paused
}

public(package) fun clt_spending_paused(config: &PlatformConfig): bool {
    config.clt_spending_paused
}

#[test_only]
public fun transferred_previous_owner(event: &AdministrationTransferred): address {
    event.previous_owner
}

#[test_only]
public fun transferred_new_owner(event: &AdministrationTransferred): address {
    event.new_owner
}

#[test_only]
public fun pause_changed_value(event: &PlatformPauseChanged): bool {
    event.paused
}

#[test_only]
public fun clt_spending_pause_changed_value(
    event: &CltSpendingPauseChanged,
): bool {
    event.paused
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
