-- HYLAR HERBS ONLY: distinct calling and WhatsApp numbers per order.
-- Apply in Supabase project wstpvrhjhscctekwbkcs, NOT any Vendstal project.
-- Additive: does not rewrite existing orders, inventory, payments or receipts.
BEGIN;

CREATE TABLE IF NOT EXISTS public.order_contact_details (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  calling_number text,
  whatsapp_number text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT hylar_contact_at_least_one
    CHECK (calling_number IS NOT NULL OR whatsapp_number IS NOT NULL)
);

ALTER TABLE public.order_contact_details ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.order_contact_details FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.order_contact_details TO authenticated;

DROP POLICY IF EXISTS "Hylar admins read order contact details" ON public.order_contact_details;
CREATE POLICY "Hylar admins read order contact details" ON public.order_contact_details
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.admins a
    WHERE a.user_id = (SELECT auth.uid())
  )
);

-- The existing submit-order Edge Function writes orders.customer_phone using
-- the legacy 'whatsapp' multipart field. This RPC safely attaches BOTH
-- numbers after that order has been committed, without changing the Edge Function.
-- No public table read/insert/update/delete permissions are granted.
CREATE OR REPLACE FUNCTION public.hylar_save_order_contacts(
  p_order_number text,
  p_contact_number text,
  p_calling_number text,
  p_whatsapp_number text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_order_id uuid;
  v_call text := NULLIF(btrim(p_calling_number), '');
  v_whatsapp text := NULLIF(btrim(p_whatsapp_number), '');
  v_primary text := NULLIF(btrim(p_contact_number), '');
  v_digits text;
  v_primary_digits text;
  v_input text;
BEGIN
  IF v_primary IS NULL OR (v_call IS NULL AND v_whatsapp IS NULL) THEN
    RAISE EXCEPTION 'Invalid order contact details' USING ERRCODE='22023';
  END IF;

  FOR v_input IN SELECT unnest(ARRAY[v_call,v_whatsapp])
  LOOP
    IF v_input IS NULL THEN CONTINUE; END IF;
    v_digits := regexp_replace(v_input, '[^0-9]', '', 'g');
    IF length(v_input) > 32 OR length(v_digits) NOT BETWEEN 7 AND 15
      OR v_input !~ '^[+0-9 ().-]+$' THEN
      RAISE EXCEPTION 'Invalid contact number' USING ERRCODE='22023';
    END IF;
  END LOOP;

  IF regexp_replace(v_primary, '[^0-9]', '', 'g')
     IS DISTINCT FROM regexp_replace(coalesce(v_call,v_whatsapp), '[^0-9]', '', 'g') THEN
    RAISE EXCEPTION 'Invalid order contact details' USING ERRCODE='22023';
  END IF;

  -- The checkout might send 0803... but an existing order handler may
  -- store it as 234803...; recognise both safely for Nigerian numbers.
  v_primary_digits := regexp_replace(v_primary, '[^0-9]', '', 'g');
  IF left(v_primary_digits, 1) = '0' THEN
    v_primary_digits := '234' || substring(v_primary_digits from 2);
  END IF;

  SELECT o.id INTO v_order_id
  FROM public.orders o
  WHERE o.order_number = btrim(p_order_number)
    AND (
      CASE
        WHEN left(regexp_replace(o.customer_phone, '[^0-9]', '', 'g'), 1) = '0'
        THEN '234' || substring(regexp_replace(o.customer_phone, '[^0-9]', '', 'g') from 2)
        ELSE regexp_replace(o.customer_phone, '[^0-9]', '', 'g')
      END
    ) = v_primary_digits
    AND o.created_at >= now() - interval '30 minutes'
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Could not verify newly submitted order'
      USING ERRCODE='42501';
  END IF;

  INSERT INTO public.order_contact_details
    (order_id, calling_number, whatsapp_number)
  VALUES (v_order_id, v_call, v_whatsapp)
  ON CONFLICT (order_id) DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.hylar_save_order_contacts(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hylar_save_order_contacts(text,text,text,text)
TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verify when complete:
-- SELECT to_regclass('public.order_contact_details') AS contact_table;
