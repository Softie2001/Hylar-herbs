# Hylar Herbs — Optional stock limits (2026-11-09)

## Decision and behavior
- **Normal selling (default):** `limits_enabled=false`. All manually available products can be ordered without a quantity cap, including products with a recorded zero count. Existing saved counts are retained.
- **Limited selling:** `limits_enabled=true`. A product must be marked manually **In stock** and have a non-null positive `stock_quantity` before an order can be submitted. `0` means sold out. A missing count is not considered unlimited while limits are on.
- **Show quantities:** `show_quantities=true` shows the exact number on product cards, individual product pages and the cart **only when limits are enabled**. When false, customers see normal availability/Out of stock without quantities.
- The admin’s existing **In stock** switch is a separate manual sellability control. Marking a product out of stock still prevents ordering regardless of global mode.
- The admin can edit quantity on the individual product form, or use the **bulk inline quantity editor** on Products and save changed rows at once.
- When the remaining count reaches zero, the product becomes unavailable in limited mode. When limits are turned off, it is orderable again if manually In stock.
- Orders submitted while limits are off are not deducted from `stock_quantity`; sellers must recount stock before another limited sale.

## Rollout
1. Review and back up the **Hylar** Supabase project (`wstpvrhjhscctekwbkcs`). **Do not run on Vendstal**.
2. Existing `supabase/stock-inventory-setup.sql` must already be applied, including its reservation/status triggers.
3. Run **`supabase/optional-stock-limits.sql`** in Hylar Supabase SQL Editor. It adds two boolean columns and replaces existing trigger functions with optional-mode logic. Both flags default to `false` and existing product counts are untouched.
4. In admin, open **Products → Product availability controls**, choose limits and quantity visibility, and save. Enter counts with the inline editor.
5. No Edge Function deployment is included. The existing `submit-order` function must insert `order_items` and propagate any trigger failures for stock enforcement. Verify this with a test order **before relying on stock caps for a real sale**.

## Verification scenarios (use test orders in the correct project)
- Limits **OFF**: quantity not set or equal to zero is not a cap; manual `in_stock=false` still prevents a sale.
- Limits **ON**: a product with a count of 3 allows exactly 3 units. Its count becomes 0 after successful order-item insert; a fourth unit/order fails in the database.
- Try two simultaneous orders for the last unit: exactly one succeeds at stock reservation.
- With Show quantities **ON**: exact count appears on storefront, cart and product details. With Show quantities **OFF**: count is hidden and server errors do not disclose it.
- Reject a limited order or cancel its delivery: reserved units return exactly once. Reconfirming a rejected order with limits ON must re-reserve or fail when insufficient.
- Turn limits OFF again: saved counts remain, and regular made-to-order purchasing resumes.
- Verify payment/receipt upload, total computation, admin orders, SEO and promotions remain functional.

## Rollback considerations
- Revert frontend commits if needed. Do **not** blindly restore the old reservation function when `limits_enabled=false`: the old function enforces counts unconditionally.
- To stop limiting safely on the new database functions: set `limits_enabled=false` using admin or SQL, then check existing order and stock records before any further DB reversal.
- Existing manual product `in_stock=false` states are deliberately not rewritten by this migration; manually re-enable any historical zero-quantity products that were previously auto-flagged Out of stock.
