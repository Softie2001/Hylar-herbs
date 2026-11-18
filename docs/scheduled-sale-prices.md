# Hylar Herbs · Scheduled sale prices

## Why this exists
Previously, every manually entered `sale_price` stayed active until removed. With 100+ products, ending promotions meant editing products individually.

This update adds:
- **Per-product** sale price + start date/time + end date/time in **Admin → Products → Edit product**.
- **Bulk scheduling** in Admin → Products for all existing unscheduled sale prices **and previously completed sale prices**. Current/upcoming schedules are not overwritten. The same discount can be reused for the next campaign.
- A dropdown to **copy the dates of an existing enabled sale banner** (Admin → Settings → Scheduled promotional banners). It copies dates when scheduling; changes to the banner afterward are not synchronized.
- A **database cron job** to activate and clear the physical `products.sale_price` field automatically. The storefront and existing `submit-order` function reference that field.

## Activation (required)
The Hylar Supabase project is **wstpvrhjhscctekwbkcs**. Do not run SQL against another project.

1. Open the Supabase SQL Editor for the **Hylar** project; back up the existing products first.
2. Run the complete `supabase/scheduled-sale-prices.sql` migration.
3. Confirm the verification result reports the **active** `hylar-scheduled-sale-sync` job.
4. In Admin → Products, check that the scheduler badge says **Scheduler ready**.

**No existing manual sale price is changed by this migration**. A manual sale only becomes scheduled after you choose dates or use the bulk scheduler.

## How pricing behaves
- **Before start time:** `sale_price = NULL`, regular price displayed and charged.
- **During the schedule:** `sale_price = scheduled_sale_price`, discounted price displayed and charged.
- **After end time:** `sale_price = NULL`, regular price displayed and charged again. The prior scheduled discount and dates are retained for audit/reuse.
- The cron job checks every minute. Activation/expiration can take up to about one minute after the configured boundary; suspended/unhealthy jobs may delay changes.
- **Without a schedule**, a manually entered sale price stays active until changed (backwards-compatible).
- Store inventory, order status, receipts, regular prices, and payment accounts are untouched.

Times entered in the admin use **Africa/Lagos / West Africa Time (UTC+01:00)**, irrespective of the admin device's timezone. We convert to UTC for storage.

## Examples
- Promo starts **December 17, 2026 09:00 WAT**, ends **December 23, 2026 23:59 WAT** → sale price reverts around the end automatically.
- If all 101 products already have a valid sale price, the bulk scheduler can set the dates in one action.
- Next campaign: previously **ended** scheduled prices are eligible for bulk reuse; active/future schedules remain unchanged.

## Verification SQL (in Hylar Supabase)
```sql
SELECT jobid, jobname, schedule, active
FROM cron.job
WHERE jobname='hylar-scheduled-sale-sync';

SELECT name, regular_price, sale_price, scheduled_sale_price,
       sale_starts_at, sale_ends_at
FROM public.products
WHERE scheduled_sale_price IS NOT NULL
ORDER BY sale_starts_at DESC LIMIT 20;

-- Diagnose recent job results if needed:
SELECT d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid=d.jobid
WHERE j.jobname='hylar-scheduled-sale-sync'
ORDER BY d.start_time DESC LIMIT 10;
```

## Important release note
GitHub Pages deployment alone does **not** activate the database schedule. The migration must be run successfully in the correct Hylar project, and an order near a sale boundary should be tested before relying on scheduled checkout prices. The existing checkout Edge Function code is not stored in this GitHub repository and has not been changed.
