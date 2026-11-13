-- HYLAR HERBS ONLY: Require BOTH contact numbers on new order contact records.
-- Apply in Supabase project wstpvrhjhscctekwbkcs AFTER separate-order-contact-numbers.sql.
-- Existing orders and existing rows (including legacy one-number rows) are preserved.
-- A NOT VALID CHECK still validates every NEW INSERT and UPDATE. No rewrite/scan of old rows.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.order_contact_details') IS NULL THEN
    RAISE EXCEPTION 'Run supabase/separate-order-contact-numbers.sql first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.order_contact_details'::regclass
      AND conname = 'hylar_new_contacts_both_required'
  ) THEN
    ALTER TABLE public.order_contact_details
      ADD CONSTRAINT hylar_new_contacts_both_required
        CHECK (
          calling_number IS NOT NULL
          AND length(btrim(calling_number)) > 0
          AND whatsapp_number IS NOT NULL
          AND length(btrim(whatsapp_number)) > 0
        ) NOT VALID;
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verify:
SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = 'public.order_contact_details'::regclass
  AND conname = 'hylar_new_contacts_both_required';

-- Expected: one row, convalidated = false.
-- False is INTENTIONAL: old rows are not changed; new rows are protected.
-- Note: the deployed legacy submit-order Edge Function first creates an order,
-- then the storefront attaches separate contacts through the Supabase RPC.
-- This constraint protects NEW contact rows, not standalone orders that
-- bypass this checkout. Full server-side order enforcement would require
-- updating the deployed submit-order Edge Function.
