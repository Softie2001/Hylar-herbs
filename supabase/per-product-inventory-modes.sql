-- Hylar Herbs: independent Unlimited / Limited inventory per product.
-- Target ONLY Hylar Supabase project wstpvrhjhscctekwbkcs.
-- Run AFTER supabase/optional-stock-limits.sql and stock-inventory-setup.sql.
-- Back up first. Existing products, orders, and quantities are preserved.
-- If store-wide limits were ON before migration, products inherit Limited;
-- otherwise products begin Unlimited until an admin opts them into limits.
-- This migration is additive/idempotent and replaces the existing stock trigger logic.
BEGIN;

DO $migration$
BEGIN
  IF to_regclass('public.products') IS NULL OR to_regclass('public.order_items') IS NULL
      OR to_regclass('public.store_settings') IS NULL THEN
    RAISE EXCEPTION 'Hylar stock tables missing: run existing stock setup first';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.order_items'::regclass
      AND tgname='hylar_reserve_stock_before_order_item_insert'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.orders'::regclass
      AND tgname='hylar_reconcile_stock_after_order_status'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Hylar stock reservation/reconciliation triggers missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='products'
      AND column_name='stock_limited'
  ) THEN
    ALTER TABLE public.products
      ADD COLUMN stock_limited boolean NOT NULL DEFAULT false;
    -- Preserve existing enforced limits if the global switch is on.
    -- Null counts remain unavailable until explicitly counted.
    UPDATE public.products
       SET stock_limited=true
     WHERE EXISTS (
       SELECT 1 FROM public.store_settings
       WHERE id=1 AND coalesce(limits_enabled,false)
     );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.products'::regclass
      AND conname='hylar_limited_products_have_stock_count'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT hylar_limited_products_have_stock_count
      CHECK (stock_limited IS NOT TRUE OR stock_quantity IS NOT NULL)
      NOT VALID;
  END IF;
END;
$migration$;

-- Order line insert: lock order + product, and reserve only Limited stock.
-- Manual in_stock remains a separate override for BOTH modes.
CREATE OR REPLACE FUNCTION public.hylar_reserve_stock_on_item_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $$
DECLARE
  v_available integer;
  v_in_stock boolean;
  v_limited boolean;
  v_payment text;
  v_delivery text;
  v_show boolean := false;
BEGIN
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid product quantity' USING ERRCODE='22023';
  END IF;
  SELECT o.payment_status::text,o.delivery_status::text
    INTO v_payment,v_delivery
  FROM public.orders o WHERE o.id=NEW.order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order does not exist' USING ERRCODE='23503';
  END IF;
  IF v_payment='not_received' OR v_delivery='cancelled' THEN
    RAISE EXCEPTION 'Cannot add products to a cancelled or rejected order'
      USING ERRCODE='23514';
  END IF;

  SELECT p.stock_quantity,p.in_stock,p.stock_limited
    INTO v_available,v_in_stock,v_limited
  FROM public.products p WHERE p.id=NEW.product_id FOR UPDATE;
  IF NOT FOUND OR v_in_stock IS NOT TRUE THEN
    RAISE EXCEPTION 'Product is out of stock' USING ERRCODE='23514';
  END IF;
  IF v_limited IS NOT TRUE THEN
    NEW.stock_reserved:=false;
    RETURN NEW;
  END IF;

  IF v_available IS NULL THEN
    RAISE EXCEPTION 'This limited product needs an available quantity'
      USING ERRCODE='23514';
  END IF;
  IF NEW.quantity>v_available THEN
    SELECT coalesce(s.show_quantities,false) INTO v_show
      FROM public.store_settings s WHERE s.id=1;
    IF coalesce(v_show,false) THEN
      RAISE EXCEPTION 'Only % unit(s) are available',v_available
        USING ERRCODE='23514';
    END IF;
    RAISE EXCEPTION 'Requested quantity exceeds available stock'
      USING ERRCODE='23514';
  END IF;
  UPDATE public.products SET stock_quantity=v_available-NEW.quantity,
    updated_at=now() WHERE id=NEW.product_id;
  -- Do not change manual in_stock; 0 limited is sold out by quantity.
  NEW.stock_reserved:=true;
  RETURN NEW;
END;
$$;

-- On cancellation/rejection always restore units that WERE reserved,
-- even if a product is now Unlimited. Reopen only currently Limited items
-- if quantity remains available; Unlimited lines do not reserve stock.
CREATE OR REPLACE FUNCTION public.hylar_reconcile_stock_on_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $$
DECLARE
  v_was_active boolean;
  v_is_active boolean;
  v_line record;
  v_available integer;
  v_in_stock boolean;
  v_limited boolean;
  v_show boolean:=false;
BEGIN
  v_was_active := (OLD.payment_status::text IS DISTINCT FROM 'not_received'
                   AND OLD.delivery_status::text IS DISTINCT FROM 'cancelled');
  v_is_active  := (NEW.payment_status::text IS DISTINCT FROM 'not_received'
                   AND NEW.delivery_status::text IS DISTINCT FROM 'cancelled');
  IF v_was_active=v_is_active THEN RETURN NEW; END IF;

  IF NOT v_is_active THEN
    FOR v_line IN
      SELECT oi.product_id,sum(oi.quantity)::integer AS units
      FROM public.order_items oi WHERE oi.order_id=NEW.id AND oi.stock_reserved=true
      GROUP BY oi.product_id ORDER BY oi.product_id
    LOOP
      UPDATE public.products p SET stock_quantity=p.stock_quantity+v_line.units,
        updated_at=now()
      WHERE p.id=v_line.product_id AND p.stock_quantity IS NOT NULL;
    END LOOP;
    UPDATE public.order_items SET stock_reserved=false
      WHERE order_id=NEW.id AND stock_reserved=true;
    RETURN NEW;
  END IF;

  FOR v_line IN
    SELECT oi.product_id,sum(oi.quantity)::integer AS units
    FROM public.order_items oi WHERE oi.order_id=NEW.id AND oi.stock_reserved=false
    GROUP BY oi.product_id ORDER BY oi.product_id
  LOOP
    SELECT p.stock_quantity,p.in_stock,p.stock_limited
      INTO v_available,v_in_stock,v_limited
    FROM public.products p WHERE p.id=v_line.product_id FOR UPDATE;
    IF NOT FOUND OR v_in_stock IS NOT TRUE THEN
      RAISE EXCEPTION 'Cannot reopen order: product is unavailable'
        USING ERRCODE='23514';
    END IF;
    IF v_limited IS NOT TRUE THEN CONTINUE; END IF;
    IF v_available IS NULL THEN
      RAISE EXCEPTION 'Cannot reopen order: limited product is uncounted'
        USING ERRCODE='23514';
    END IF;
    IF v_available<v_line.units THEN
      SELECT coalesce(s.show_quantities,false) INTO v_show
        FROM public.store_settings s WHERE s.id=1;
      IF coalesce(v_show,false) THEN
        RAISE EXCEPTION 'Cannot reopen order: only % unit(s) available',
          v_available USING ERRCODE='23514';
      END IF;
      RAISE EXCEPTION 'Cannot reopen order: insufficient stock'
        USING ERRCODE='23514';
    END IF;
    UPDATE public.products SET stock_quantity=v_available-v_line.units,
      updated_at=now() WHERE id=v_line.product_id;
    UPDATE public.order_items SET stock_reserved=true
      WHERE order_id=NEW.id AND product_id=v_line.product_id
        AND stock_reserved=false;
  END LOOP;
  RETURN NEW;
END;
$$;

-- Keep trigger functions inaccessible as public browser RPCs.
REVOKE ALL ON FUNCTION public.hylar_reserve_stock_on_item_insert()
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.hylar_reconcile_stock_on_order_status()
  FROM PUBLIC,anon,authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;

-- Verify in HYlar project after SQL has completed:
SELECT
  count(*) FILTER (WHERE stock_limited) AS limited_products,
  count(*) FILTER (WHERE NOT stock_limited) AS unlimited_products,
  count(*) FILTER (WHERE stock_limited AND stock_quantity IS NULL) AS limited_without_count
FROM public.products;

-- IMPORTANT: This migration does not deploy code or update admin UI.
-- The admin/storefront updates must also be published from GitHub.
