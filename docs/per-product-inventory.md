# Hylar Herbs: per-product inventory

## Activation
Run [supabase/per-product-inventory-modes.sql](../supabase/per-product-inventory-modes.sql) in **only** the Hylar Supabase project `wstpvrhjhscctekwbkcs`, after backing up the existing data.

This SQL is **required** before the new inventory controls become active. The deployed frontend gracefully keeps legacy availability behavior until the new column is present.

## Using Admin → Products
1. In the product list, select **Unlimited** or **Limited** for each item, or open **Edit Product**.
2. **Unlimited**: no count is required or deducted; no "Unlimited" badge or number appears in the shop.
3. **Limited**: enter a fresh quantity, e.g. 10 or 20, then save the product. Zero means **Out of Stock**, regardless of the public display setting.
4. The single store-wide **Show remaining units to customers** switch controls only the visibility of **positive Limited product quantities**. It does not turn limits on or off.
5. Manually marking a product **Out of stock** remains an override for either inventory mode.
6. For products already Limited, the inline quantity editor allows bulk count updates.
7. When switching from Unlimited to Limited, enter a fresh count; previously saved counts were not decremented during unlimited sales.

## Existing data
- Product rows, current quantities and existing orders are not deleted.
- If the legacy global limit setting was enabled when migration runs, products inherit Limited behavior; otherwise, they default to Unlimited and may be changed individually.
- Only Limited products are reserved/deducted through the order-item transaction trigger. Reserved counts are restored on cancellation/rejection and may be re-reserved when orders are reopened. Unlimited products never have counts deducted on new orders.
- Historical reserved line items may still restore their counts when canceled, even if the product is now Unlimited. The displayed Unlimited behavior is unaffected.

## Verification in the Hylar SQL Editor
```sql
SELECT id, name, stock_limited, stock_quantity, in_stock
FROM public.products ORDER BY name LIMIT 25;

SELECT
  count(*) FILTER (WHERE stock_limited) AS limited_products,
  count(*) FILTER (WHERE NOT stock_limited) AS unlimited_products
FROM public.products;

SELECT tgname FROM pg_trigger
WHERE tgrelid = 'public.order_items'::regclass
AND tgname='hylar_reserve_stock_before_order_item_insert';

SELECT tgname FROM pg_trigger
WHERE tgrelid='public.orders'::regclass
AND tgname='hylar_reconcile_stock_after_order_status';
```

## Test cases before using production orders
- **Unlimited**, even with an old saved count of 0: shown as an ordinary product, no unit label, orders do not deduct stock.
- **Limited 10**, show units ON: display **10 units available** and restrict orders to 10.
- **Limited 10**, show units OFF: no unit number, but restrict orders to 10.
- **Limited 0**: **Out of Stock** whether unit numbers are ON or OFF.
- **Manual Out of Stock**: unavailable even when Unlimited.
- Test a canceled limited order to confirm units restore. Do not submit fake payment receipts for tests.

No new hosting provider, package, service or paid feature is introduced.
