module game_economy::product_catalog;

use game_economy::platform::AdminCap;
use sui::event;
use sui::table::{Self, Table};

const EProductAlreadyExists: u64 = 0;
const EProductNotFound: u64 = 1;
const EInvalidProductPrice: u64 = 2;
const EProductInactive: u64 = 3;
const EGlobalSalesLimitReached: u64 = 4;
const EPlayerPurchaseLimitReached: u64 = 5;
const EInvalidSalesLimit: u64 = 6;
const EProductAlreadyEnabled: u64 = 7;
const EProductAlreadyDisabled: u64 = 8;
const EPurchaseAlreadyProcessed: u64 = 9;

/// The single shared product catalog for this game.
public struct ProductCatalog has key {
    id: UID,
    products: Table<u64, Product>,
    player_purchase_counts: Table<PlayerProductKey, u64>,
    processed_orders: Table<vector<u8>, bool>,
}

/// Zero for either limit means unlimited. Historical counts are never reset.
public struct Product has store {
    price: u64,
    active: bool,
    sales_limit: u64,
    sold_count: u64,
    per_player_limit: u64,
}

public struct PlayerProductKey(u64, address) has copy, drop, store;

public struct ProductCreated has copy, drop {
    product_id: u64,
    price: u64,
    sales_limit: u64,
    per_player_limit: u64,
}

public struct ProductPriceUpdated has copy, drop {
    product_id: u64,
    old_price: u64,
    new_price: u64,
}

public struct ProductStatusUpdated has copy, drop {
    product_id: u64,
    active: bool,
}

public struct ProductLimitsUpdated has copy, drop {
    product_id: u64,
    old_sales_limit: u64,
    new_sales_limit: u64,
    old_per_player_limit: u64,
    new_per_player_limit: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(ProductCatalog {
        id: object::new(ctx),
        products: table::new(ctx),
        player_purchase_counts: table::new(ctx),
        processed_orders: table::new(ctx),
    });
}

/// Creates an active product with an administrator-supplied stable ID.
public fun create_product(
    catalog: &mut ProductCatalog,
    _admin_cap: &AdminCap,
    product_id: u64,
    price: u64,
    sales_limit: u64,
    per_player_limit: u64,
) {
    assert!(
        !table::contains(&catalog.products, product_id),
        EProductAlreadyExists,
    );
    assert!(price > 0, EInvalidProductPrice);

    table::add(
        &mut catalog.products,
        product_id,
        Product {
            price,
            active: true,
            sales_limit,
            sold_count: 0,
            per_player_limit,
        },
    );
    event::emit(ProductCreated {
        product_id,
        price,
        sales_limit,
        per_player_limit,
    });
}

public fun update_product_price(
    catalog: &mut ProductCatalog,
    _admin_cap: &AdminCap,
    product_id: u64,
    new_price: u64,
) {
    assert!(new_price > 0, EInvalidProductPrice);
    let product = product_mut(catalog, product_id);
    let old_price = product.price;
    product.price = new_price;
    event::emit(ProductPriceUpdated {
        product_id,
        old_price,
        new_price,
    });
}

public fun enable_product(
    catalog: &mut ProductCatalog,
    _admin_cap: &AdminCap,
    product_id: u64,
) {
    let product = product_mut(catalog, product_id);
    assert!(!product.active, EProductAlreadyEnabled);
    product.active = true;
    event::emit(ProductStatusUpdated {
        product_id,
        active: true,
    });
}

public fun disable_product(
    catalog: &mut ProductCatalog,
    _admin_cap: &AdminCap,
    product_id: u64,
) {
    let product = product_mut(catalog, product_id);
    assert!(product.active, EProductAlreadyDisabled);
    product.active = false;
    event::emit(ProductStatusUpdated {
        product_id,
        active: false,
    });
}

/// Updates optional limits without changing historical purchase counters.
public fun update_product_limits(
    catalog: &mut ProductCatalog,
    _admin_cap: &AdminCap,
    product_id: u64,
    new_sales_limit: u64,
    new_per_player_limit: u64,
) {
    let product = product_mut(catalog, product_id);
    assert!(
        new_sales_limit == 0 || new_sales_limit >= product.sold_count,
        EInvalidSalesLimit,
    );
    let old_sales_limit = product.sales_limit;
    let old_per_player_limit = product.per_player_limit;
    product.sales_limit = new_sales_limit;
    product.per_player_limit = new_per_player_limit;
    event::emit(ProductLimitsUpdated {
        product_id,
        old_sales_limit,
        new_sales_limit,
        old_per_player_limit,
        new_per_player_limit,
    });
}

fun product_exists(
    catalog: &ProductCatalog,
    product_id: u64,
): bool {
    table::contains(&catalog.products, product_id)
}

#[test_only]
public fun product_price(catalog: &ProductCatalog, product_id: u64): u64 {
    product(catalog, product_id).price
}

#[test_only]
public fun product_active(
    catalog: &ProductCatalog,
    product_id: u64,
): bool {
    product(catalog, product_id).active
}

#[test_only]
public fun product_sold_count(
    catalog: &ProductCatalog,
    product_id: u64,
): u64 {
    product(catalog, product_id).sold_count
}

#[test_only]
public fun product_sales_limit(
    catalog: &ProductCatalog,
    product_id: u64,
): u64 {
    product(catalog, product_id).sales_limit
}

#[test_only]
public fun product_per_player_limit(
    catalog: &ProductCatalog,
    product_id: u64,
): u64 {
    product(catalog, product_id).per_player_limit
}

#[test_only]
public fun player_purchase_count_for_testing(
    catalog: &ProductCatalog,
    product_id: u64,
    player: address,
): u64 {
    assert!(product_exists(catalog, product_id), EProductNotFound);
    let key = PlayerProductKey(product_id, player);
    if (table::contains(&catalog.player_purchase_counts, key)) {
        *table::borrow(&catalog.player_purchase_counts, key)
    } else {
        0
    }
}

#[test_only]
public fun product_count(catalog: &ProductCatalog): u64 {
    catalog.products.length()
}

#[test_only]
public fun processed_order_count(catalog: &ProductCatalog): u64 {
    catalog.processed_orders.length()
}

#[test_only]
public fun order_processed(
    catalog: &ProductCatalog,
    order_id: vector<u8>,
): bool {
    table::contains(&catalog.processed_orders, order_id)
}

/// Performs product, limit, and replay validation before payment consumption.
public(package) fun validate_purchase(
    catalog: &ProductCatalog,
    product_id: u64,
    player: address,
    order_id: &vector<u8>,
): u64 {
    let product = product(catalog, product_id);
    assert!(product.active, EProductInactive);
    assert!(
        product.sales_limit == 0 || product.sold_count < product.sales_limit,
        EGlobalSalesLimitReached,
    );
    let count = player_purchase_count(catalog, product_id, player);
    assert!(
        product.per_player_limit == 0 || count < product.per_player_limit,
        EPlayerPurchaseLimitReached,
    );
    assert!(
        !table::contains(&catalog.processed_orders, *order_id),
        EPurchaseAlreadyProcessed,
    );
    product.price
}

/// Commits counters and replay state after policy confirmation succeeds.
public(package) fun record_purchase(
    catalog: &mut ProductCatalog,
    product_id: u64,
    buyer: address,
    order_id: vector<u8>,
) {
    let product = product_mut(catalog, product_id);
    product.sold_count = product.sold_count + 1;

    let key = PlayerProductKey(product_id, buyer);
    if (table::contains(&catalog.player_purchase_counts, key)) {
        let count = table::borrow_mut(&mut catalog.player_purchase_counts, key);
        *count = *count + 1;
    } else {
        table::add(&mut catalog.player_purchase_counts, key, 1);
    };

    table::add(&mut catalog.processed_orders, order_id, true);
}

fun product(catalog: &ProductCatalog, product_id: u64): &Product {
    assert!(product_exists(catalog, product_id), EProductNotFound);
    table::borrow(&catalog.products, product_id)
}

fun product_mut(catalog: &mut ProductCatalog, product_id: u64): &mut Product {
    assert!(product_exists(catalog, product_id), EProductNotFound);
    table::borrow_mut(&mut catalog.products, product_id)
}

fun player_purchase_count(
    catalog: &ProductCatalog,
    product_id: u64,
    player: address,
): u64 {
    assert!(product_exists(catalog, product_id), EProductNotFound);
    let key = PlayerProductKey(product_id, player);
    if (table::contains(&catalog.player_purchase_counts, key)) {
        *table::borrow(&catalog.player_purchase_counts, key)
    } else {
        0
    }
}

#[test_only]
public fun product_exists_for_testing(
    catalog: &ProductCatalog,
    product_id: u64,
): bool {
    product_exists(catalog, product_id)
}

#[test_only]
public fun created_product_id(event: &ProductCreated): u64 { event.product_id }

#[test_only]
public fun created_price(event: &ProductCreated): u64 { event.price }

#[test_only]
public fun created_sales_limit(event: &ProductCreated): u64 { event.sales_limit }

#[test_only]
public fun created_per_player_limit(event: &ProductCreated): u64 {
    event.per_player_limit
}

#[test_only]
public fun price_updated_old_price(event: &ProductPriceUpdated): u64 {
    event.old_price
}

#[test_only]
public fun price_updated_new_price(event: &ProductPriceUpdated): u64 {
    event.new_price
}

#[test_only]
public fun status_updated_active(event: &ProductStatusUpdated): bool {
    event.active
}

#[test_only]
public fun limits_updated_old_sales_limit(event: &ProductLimitsUpdated): u64 {
    event.old_sales_limit
}

#[test_only]
public fun limits_updated_new_sales_limit(event: &ProductLimitsUpdated): u64 {
    event.new_sales_limit
}

#[test_only]
public fun limits_updated_old_per_player_limit(event: &ProductLimitsUpdated): u64 {
    event.old_per_player_limit
}

#[test_only]
public fun limits_updated_new_per_player_limit(event: &ProductLimitsUpdated): u64 {
    event.new_per_player_limit
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
