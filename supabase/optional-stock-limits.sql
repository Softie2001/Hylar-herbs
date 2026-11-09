-- Hylar Herbs | Optional stock limits & public quantity display
-- Run ONLY in Hylar Supabase project wstpvrhjhscctekwbkcs, after backing up.
-- Requires the existing stock-inventory-setup.sql migration and its triggers.
-- Safe first state: limits OFF; public quantities HIDDEN. Existing products/counts unchanged.
-- Turning ON limits requires entering a quantity for each sellable product.
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.order_items'::regclass
      AND tgname = 'hylar_reserve_stock_before_order_item_insert'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION
      'Install supabase/stock-inventory-setup.sql first: order-item reservation trigger missing.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.orders'::regclass
      AND tgname = 'hylar_reconcile_stock_after_order_status'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION
      'Install supabase/stock-inventory-setup.sql first: order-status trigger missing.';
  END IF;
END;
$$;

ALTER TABLE public.store_settings
  ADD COLUMN IF NOT EXISTS limits_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS show_quantities boolean NOT NULL DEFAULT false;

-- Existing product manual in_stock controls remain valid at all times.
-- When limits are on, count NULL means NOT READY for limited sales; 0 means sold out.
-- When limits are off, counted quantities are stored but do not restrict orders.
-- The insert trigger still serializes the order and product with row locks.
CREATE OR REPLACE FUNCTION public.hylar_reserve_stock_on_item_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
  v_available integer;
  v_manual_in_stock boolean;
  v_payment text;
  v_delivery text;
  v_limits boolean := false;
  v_show boolean := false;
BEGIN
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid product quantity' USING ERRCODE = '22023';
  END IF;

  SELECT o.payment_status::text, o.delivery_status::text
    INTO v_payment, v_delivery
  FROM public.orders AS o WHERE o.id = NEW.order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order does not exist' USING ERRCODE = '23503';
  END IF;
  IF v_payment = 'not_received' OR v_delivery = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot add products to a cancelled or rejected order'
      USING ERRCODE = '23514';
  END IF;

  SELECT p.stock_quantity, p.in_stock
    INTO v_available, v_manual_in_stock
  FROM public.products AS p WHERE p.id = NEW.product_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product is unavailable' USING ERRCODE = '23503';
  END IF;
  IF v_manual_in_stock IS NOT TRUE THEN
    RAISE EXCEPTION 'Product is out of stock' USING ERRCODE = '23514';
  END IF;

  SELECT coalesce(s.limits_enabled,false),coalesce(s.show_quantities,false)
    INTO v_limits, v_show
  FROM public.store_settings AS s WHERE s.id=1;
  IF coalesce(v_limits,false) IS NOT TRUE THEN
    NEW.stock_reserved := false;
    RETURN NEW;
  END IF;

  IF v_available IS NULL THEN
    RAISE EXCEPTION 'This product is not yet counted for limited sales'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.quantity > v_available THEN
    IF coalesce(v_show,false) THEN
      RAISE EXCEPTION 'Only % unit(s) are available',v_available
        USING ERRCODE = '23514';
    ELSE
      RAISE EXCEPTION 'Requested quantity exceeds available stock'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  UPDATE public.products
     SET stock_quantity = v_available - NEW.quantity, updated_at = now()
   WHERE id = NEW.product_id;
  -- Do not alter manual in_stock: public sold-out status is derived from quantity.
  NEW.stock_reserved := true;
  RETURN NEW;
END;
$$;

-- Restore reserved units on rejection/cancellation, even if limits are now OFF.
-- Reopening or reconfirming a released order reserves again ONLY if limits are ON.
CREATE OR REPLACE FUNCTION public.hylar_reconcile_stock_on_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
  v_was_active boolean;
  v_is_active boolean;
  v_limits boolean := false;
  v_show boolean := false;
  v_line record;
  v_available integer;
  v_manual_in_stock boolean;
BEGIN
  v_was_active := (OLD.payment_status::text IS DISTINCT FROM 'not_received'
                   AND OLD.delivery_status::text IS DISTINCT FROM 'cancelled');
  v_is_active := (NEW.payment_status::text IS DISTINCT FROM 'not_received'
                  AND NEW.delivery_status::text IS DISTINCT FROM 'cancelled');
  IF v_was_active = v_is_active THEN RETURN NEW; END IF;

  IF NOT v_is_active THEN
    FOR v_line IN
      SELECT oi.product_id, sum(oi.quantity)::integer AS units
      FROM public.order_items AS oi
      WHERE oi.order_id=NEW.id AND oi.stock_reserved=true
      GROUP BY oi.product_id ORDER BY oi.product_id
    LOOP
      UPDATE public.products AS p
         SET stock_quantity=p.stock_quantity+v_line.units,updated_at=now()
       WHERE p.id=v_line.product_id AND p.stock_quantity IS NOT NULL;
    END LOOP;
    UPDATE public.order_items
       SET stock_reserved=false
     WHERE order_id=NEW.id AND stock_reserved=true;
    RETURN NEW;
  END IF;

  SELECT coalesce(s.limits_enabled,false),coalesce(s.show_quantities,false)
    INTO v_limits,v_show
  FROM public.store_settings AS s WHERE s.id=1;
  IF coalesce(v_limits,false) IS NOT TRUE THEN RETURN NEW; END IF;

  FOR v_line IN
    SELECT oi.product_id, sum(oi.quantity)::integer AS units
    FROM public.order_items AS oi
    WHERE oi.order_id=NEW.id AND oi.stock_reserved=false
    GROUP BY oi.product_id ORDER BY oi.product_id
  LOOP
    SELECT p.stock_quantity,p.in_stock INTO v_available,v_manual_in_stock
      FROM public.products AS p WHERE p.id=v_line.product_id FOR UPDATE;
    IF NOT FOUND OR v_manual_in_stock IS NOT TRUE OR v_available IS NULL THEN
      RAISE EXCEPTION 'Cannot reopen order: product is unavailable or uncounted'
        USING ERRCODE = '23514';
    END IF;
    IF v_available<v_line.units THEN
      IF coalesce(v_show,false) THEN
        RAISE EXCEPTION 'Cannot reopen order: only % unit(s) available',v_available
          USING ERRCODE = '23514';
      ELSE
        RAISE EXCEPTION 'Cannot reopen order: insufficient stock'
          USING ERRCODE = '23514';
      END IF;
    END IF;
    UPDATE public.products
       SET stock_quantity=v_available-v_line.units,updated_at=now()
     WHERE id=v_line.product_id;
    UPDATE public.order_items
       SET stock_reserved=true
     WHERE order_id=NEW.id AND product_id=v_line.product_id AND stock_reserved=false;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.hylar_release_stock_on_item_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
BEGIN
  IF OLD.stock_reserved IS TRUE THEN
    UPDATE public.products AS p
       SET stock_quantity=p.stock_quantity+OLD.quantity,updated_at=now()
     WHERE p.id=OLD.product_id AND p.stock_quantity IS NOT NULL;
  END IF;
  RETURN OLD;
END;
$$;

-- Keep functions executable only through existing triggers, not browser RPCs.
REVOKE ALL ON FUNCTION public.hylar_reserve_stock_on_item_insert() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.hylar_reconcile_stock_on_order_status() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.hylar_release_stock_on_item_delete() FROM PUBLIC,anon,authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;

-- After applying, confirm store_settings row 1 is present and both flags are false:
-- SELECT id, limits_enabled, show_quantities FROM public.store_settings WHERE id=1;
-- SELECT count(*) AS products_still_listed FROM public.products WHERE visible=true;
-- Existing stock_quantity values and manual in_stock flags have not been changed.
