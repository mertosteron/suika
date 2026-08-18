module game_economy::purchase;

use game_economy::game_credit::{Self, GAME_CREDIT};
use game_economy::platform::{Self, PlatformConfig};
use game_economy::product_catalog::{Self, ProductCatalog};
use sui::event;
use sui::token::{Token, TokenPolicy};

const ORDER_ID_LENGTH: u64 = 32;

const EPlatformPaused: u64 = 0;
const EInvalidPaymentAmount: u64 = 1;
const EZeroPayment: u64 = 2;
const EInvalidOrderId: u64 = 3;
const EBuyerMismatch: u64 = 4;
const ECltSpendingPaused: u64 = 5;

/// Records accepted CLT payment for off-chain product fulfillment.
public struct PurchaseCompleted has copy, drop {
    buyer: address,
    product_id: u64,
    amount: u64,
    order_id: vector<u8>,
}

/// Purchases one catalog product with an exact closed-loop Token payment.
///
/// Product, limit, replay, and amount validation precedes policy confirmation.
/// Catalog counters are committed only after the policy consumes the payment.
public fun purchase_catalog_product(
    config: &PlatformConfig,
    catalog: &mut ProductCatalog,
    policy: &mut TokenPolicy<GAME_CREDIT>,
    payment: Token<GAME_CREDIT>,
    product_id: u64,
    order_id: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(!platform::paused(config), EPlatformPaused);
    assert!(!platform::clt_spending_paused(config), ECltSpendingPaused);
    assert!(order_id.length() == ORDER_ID_LENGTH, EInvalidOrderId);

    let buyer = ctx.sender();
    let expected_amount = product_catalog::validate_purchase(
        catalog,
        product_id,
        buyer,
        &order_id,
    );
    let submitted_amount = payment.value();
    assert!(submitted_amount > 0, EZeroPayment);
    assert!(submitted_amount == expected_amount, EInvalidPaymentAmount);

    let (amount, request_sender) = game_credit::consume_purchase_payment(
        policy,
        payment,
        ctx,
    );
    assert!(request_sender == buyer, EBuyerMismatch);
    product_catalog::record_purchase(catalog, product_id, buyer, order_id);
    event::emit(PurchaseCompleted {
        buyer,
        product_id,
        amount,
        order_id,
    });
}

#[test_only]
public fun order_id_length(): u64 {
    ORDER_ID_LENGTH
}

#[test_only]
public fun completed_buyer(event: &PurchaseCompleted): address { event.buyer }

#[test_only]
public fun completed_product_id(event: &PurchaseCompleted): u64 {
    event.product_id
}

#[test_only]
public fun completed_amount(event: &PurchaseCompleted): u64 { event.amount }

#[test_only]
public fun completed_order_id(event: &PurchaseCompleted): vector<u8> {
    event.order_id
}
