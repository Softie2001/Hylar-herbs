-- HYLAR HERBS ONLY: Automatic start/end times for sale pricing.
-- Target: Supabase project wstpvrhjhscctekwbkcs.
-- Safe for existing manual sale_price entries; nothing changes until scheduled.
-- Requires Supabase Cron (pg_cron). Running this SQL installs a once-per-minute
-- job which updates the SAME products.sale_price field read by submit-order.
-- All timestamps are TIMESTAMPTZ. Admin UI enters times in Lagos (WAT/UTC+1).
BEGIN;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS scheduled_sale_price numeric,
  ADD COLUMN IF NOT EXISTS sale_starts_at timestamptz,
  ADD COLUMN IF NOT EXISTS sale_ends_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.products'::regclass
      AND conname='hylar_valid_scheduled_sale'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT hylar_valid_scheduled_sale
      CHECK (
        (
          scheduled_sale_price IS NULL
          AND sale_starts_at IS NULL
          AND sale_ends_at IS NULL
        ) OR (
          regular_price IS NOT NULL
          AND scheduled_sale_price > 0
          AND scheduled_sale_price < regular_price
          AND sale_starts_at IS NOT NULL
          AND sale_ends_at IS NOT NULL
          AND sale_starts_at < sale_ends_at
        )
      );
  END IF;
END;
$$;

-- A product editor/bulk action may save a scheduled price before its start.
-- On save, write sale_price only if the schedule is currently active.
-- A manual (unscheduled) sale_price is left unchanged.
CREATE OR REPLACE FUNCTION public.hylar_apply_sale_schedule()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $$
BEGIN
  IF NEW.scheduled_sale_price IS NOT NULL THEN
    IF NEW.sale_starts_at <= now() AND now() < NEW.sale_ends_at THEN
      NEW.sale_price := NEW.scheduled_sale_price;
    ELSE
      NEW.sale_price := NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS hylar_apply_sale_schedule_before_save ON public.products;
CREATE TRIGGER hylar_apply_sale_schedule_before_save
BEFORE INSERT OR UPDATE OF
  scheduled_sale_price, sale_starts_at, sale_ends_at, regular_price
ON public.products
FOR EACH ROW EXECUTE FUNCTION public.hylar_apply_sale_schedule();

-- Cron flips sale_price on and off (at most ~1 minute delay).
-- This is essential because the existing checkout function uses products.sale_price.
CREATE OR REPLACE FUNCTION public.hylar_sync_scheduled_sales()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.products p
    SET sale_price = CASE
      WHEN now() >= p.sale_starts_at AND now() < p.sale_ends_at
      THEN p.scheduled_sale_price ELSE NULL END,
      updated_at = now()
  WHERE p.scheduled_sale_price IS NOT NULL
    AND p.sale_starts_at IS NOT NULL
    AND p.sale_ends_at IS NOT NULL
    AND p.sale_price IS DISTINCT FROM (
      CASE WHEN now() >= p.sale_starts_at AND now() < p.sale_ends_at
      THEN p.scheduled_sale_price ELSE NULL END
    );
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.hylar_apply_sale_schedule()
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.hylar_sync_scheduled_sales()
  FROM PUBLIC,anon,authenticated;

-- Bulk scheduling for the admin: valid MANUAL sale prices and completed
-- scheduled sales can be reused. Upcoming / currently active schedules stay
-- untouched, so the next 100-product sale never needs manual cleanup.
CREATE OR REPLACE FUNCTION public.hylar_schedule_current_sale_prices(
  p_start_at timestamptz,
  p_end_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.admins a WHERE a.user_id=(SELECT auth.uid())
  ) THEN
    RAISE EXCEPTION 'Only Hylar admins can schedule sales'
      USING ERRCODE='42501';
  END IF;
  IF p_start_at IS NULL OR p_end_at IS NULL
    OR p_end_at <= p_start_at OR p_end_at <= now() THEN
    RAISE EXCEPTION 'Choose a valid future end date after the start date'
      USING ERRCODE='22023';
  END IF;
  UPDATE public.products p
    SET scheduled_sale_price=coalesce(p.scheduled_sale_price,p.sale_price),
        sale_starts_at=p_start_at,
        sale_ends_at=p_end_at,
        updated_at=now()
  WHERE (
      (p.scheduled_sale_price IS NULL AND p.sale_price > 0
       AND p.sale_price < p.regular_price)
      OR
      (p.scheduled_sale_price IS NOT NULL AND p.sale_ends_at <= now()
       AND p.scheduled_sale_price > 0
       AND p.scheduled_sale_price < p.regular_price)
    );
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION
  public.hylar_schedule_current_sale_prices(timestamptz,timestamptz)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  public.hylar_schedule_current_sale_prices(timestamptz,timestamptz)
  TO authenticated;

-- Supabase Cron schedules an internal SQL job: no external service or API key.
-- If this fails, the transaction rolls back rather than claiming auto-expiry.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

SELECT cron.schedule(
  'hylar-scheduled-sale-sync',
  '* * * * *',
  'SELECT public.hylar_sync_scheduled_sales();'
);

NOTIFY pgrst,'reload schema';
COMMIT;

-- Verification: confirm one cron job is active.
SELECT jobid,jobname,schedule,active
FROM cron.job WHERE jobname='hylar-scheduled-sale-sync';

SELECT COUNT(*) FILTER (WHERE scheduled_sale_price IS NOT NULL) AS scheduled,
       COUNT(*) FILTER (WHERE scheduled_sale_price IS NULL AND sale_price IS NOT NULL) AS manual_sales
FROM public.products;
