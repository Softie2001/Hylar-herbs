-- HYlar Herbs | quantity-based inventory | 2026-11-06
-- TARGET ONLY: Supabase project wstpvrhjhscctekwbkcs.
-- REVIEW EXISTING TABLES + MAKE A BACKUP BEFORE RUNNING IN ITS SQL EDITOR.
-- Do not run this on any other project. Nothing in this ZIP executes SQL automatically.
-- The existing submit-order Edge Function must insert order_items and propagate errors.
-- Do not rely on browser-only checks for overselling protection.

BEGIN;

-- NULL = legacy product whose stock has not yet been counted by the admin.
-- A measured quantity of 0 means sold out. Existing products remain available
-- as before until the admin enters their real quantities (avoids taking the
-- existing store offline during rollout).
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS stock_quantity integer;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass
      AND conname = 'hylar_stock_quantity_nonnegative'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT hylar_stock_quantity_nonnegative
      CHECK (stock_quantity IS NULL OR stock_quantity >= 0);
  END IF;
END;
$$;

-- Distinguishes stock reserved under this rollout from historical order lines.
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS stock_reserved boolean NOT NULL DEFAULT false;

-- Runs in the SAME Postgres transaction as each order_item INSERT. Row locks
-- serialize competing customers, so at most one can buy the final unit.
-- Uses normal invoker privileges (typically the existing Edge Function's
-- service role); no public SECURITY DEFINER RPC or new public write grants.
CREATE OR REPLACE FUNCTION public.hylar_reserve_stock_on_item_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_available integer;
  v_in_stock boolean;
  v_payment text;
  v_delivery text;
BEGIN
  IF NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid product quantity' USING ERRCODE = '22023';
  END IF;

  -- This locks the parent order so cancel/confirm and item inserts are serialized.
  SELECT o.payment_status::text, o.delivery_status::text
    INTO v_payment, v_delivery
  FROM public.orders AS o
  WHERE o.id = NEW.order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order no longer exists' USING ERRCODE = '23503';
  END IF;
  IF v_payment = 'not_received' OR v_delivery = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot add products to a cancelled or rejected order'
      USING ERRCODE = '23514';
  END IF;

  SELECT p.stock_quantity, p.in_stock
    INTO v_available, v_in_stock
  FROM public.products AS p
  WHERE p.id = NEW.product_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product is no longer available' USING ERRCODE = '23503';
  END IF;
  IF v_in_stock IS NOT TRUE THEN
    RAISE EXCEPTION 'Product is out of stock' USING ERRCODE = '23514';
  END IF;

  IF v_available IS NOT NULL THEN
    IF NEW.quantity > v_available THEN
      RAISE EXCEPTION 'Only % unit(s) left in stock', v_available
        USING ERRCODE = '23514';
    END IF;
    UPDATE public.products
       SET stock_quantity = v_available - NEW.quantity,
           in_stock = (v_available - NEW.quantity > 0),
           updated_at = now()
     WHERE id = NEW.product_id;
    NEW.stock_reserved := true;
  ELSE
    -- Legacy, uncounted product: old in_stock behavior remains until counted.
    NEW.stock_reserved := false;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS hylar_reserve_stock_before_order_item_insert ON public.order_items;
CREATE TRIGGER hylar_reserve_stock_before_order_item_insert
BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.hylar_reserve_stock_on_item_insert();

-- Direct edits to placed-order quantities could otherwise desynchronize
-- inventory. Cancel and resubmit instead of changing historical order lines.
CREATE OR REPLACE FUNCTION public.hylar_protect_order_item_quantity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.quantity IS DISTINCT FROM OLD.quantity
      OR NEW.product_id IS DISTINCT FROM OLD.product_id THEN
    RAISE EXCEPTION 'Placed order items cannot change product or quantity'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS hylar_protect_order_item_update ON public.order_items;
CREATE TRIGGER hylar_protect_order_item_update
BEFORE UPDATE OF quantity, product_id ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.hylar_protect_order_item_quantity();

-- When payment is marked NOT RECEIVED or delivery CANCELLED, release held
-- units once. If the admin later re-confirms/reopens that order, re-reserve
-- only if enough stock is still available; otherwise refuse the status change.
CREATE OR REPLACE FUNCTION public.hylar_reconcile_stock_on_order_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_was_active boolean;
  v_is_active boolean;
  v_line record;
  v_available integer;
  v_sellable boolean;
BEGIN
  v_was_active := (OLD.payment_status::text IS DISTINCT FROM 'not_received'
                   AND OLD.delivery_status::text IS DISTINCT FROM 'cancelled');
  v_is_active := (NEW.payment_status::text IS DISTINCT FROM 'not_received'
                  AND NEW.delivery_status::text IS DISTINCT FROM 'cancelled');
  IF v_was_active = v_is_active THEN
    RETURN NEW;
  END IF;

  IF NOT v_is_active THEN
    FOR v_line IN
      SELECT oi.product_id, SUM(oi.quantity)::integer AS units
      FROM public.order_items AS oi
      WHERE oi.order_id = NEW.id AND oi.stock_reserved = true
      GROUP BY oi.product_id ORDER BY oi.product_id
    LOOP
      UPDATE public.products AS p
         SET stock_quantity = p.stock_quantity + v_line.units,
             -- Auto-reopen only items sold out by quantity reaching zero.
             in_stock = CASE WHEN p.stock_quantity = 0 THEN true ELSE p.in_stock END,
             updated_at = now()
       WHERE p.id = v_line.product_id AND p.stock_quantity IS NOT NULL;
    END LOOP;
    UPDATE public.order_items
       SET stock_reserved = false
     WHERE order_id = NEW.id AND stock_reserved = true;
  ELSE
    -- Reopening an order is permitted only after its inventory is re-reserved.
    FOR v_line IN
      SELECT oi.product_id, SUM(oi.quantity)::integer AS units
      FROM public.order_items AS oi
      WHERE oi.order_id = NEW.id AND oi.stock_reserved = false
      GROUP BY oi.product_id ORDER BY oi.product_id
    LOOP
      SELECT p.stock_quantity, p.in_stock
        INTO v_available, v_sellable
      FROM public.products AS p
      WHERE p.id = v_line.product_id
      FOR UPDATE;
      IF NOT FOUND OR v_sellable IS NOT TRUE THEN
        RAISE EXCEPTION 'Cannot reopen order: a product is unavailable'
          USING ERRCODE = '23514';
      END IF;
      IF v_available IS NOT NULL THEN
        IF v_available < v_line.units THEN
          RAISE EXCEPTION 'Cannot reopen order: only % unit(s) remain', v_available
            USING ERRCODE = '23514';
        END IF;
        UPDATE public.products
           SET stock_quantity = v_available - v_line.units,
               in_stock = (v_available - v_line.units > 0),
               updated_at = now()
         WHERE id = v_line.product_id;
        UPDATE public.order_items
           SET stock_reserved = true
         WHERE order_id = NEW.id AND product_id = v_line.product_id
           AND stock_reserved = false;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS hylar_reconcile_stock_after_order_status ON public.orders;
CREATE TRIGGER hylar_reconcile_stock_after_order_status
AFTER UPDATE OF payment_status, delivery_status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.hylar_reconcile_stock_on_order_status();

-- Deleting an active item (including via order cascade) puts its held units
-- back. Existing stock counts are never decremented on payment confirmation:
-- reservation already happened on order submission.
CREATE OR REPLACE FUNCTION public.hylar_release_stock_on_item_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF OLD.stock_reserved IS TRUE THEN
    UPDATE public.products AS p
       SET stock_quantity = p.stock_quantity + OLD.quantity,
           in_stock = CASE WHEN p.stock_quantity = 0 THEN true ELSE p.in_stock END,
           updated_at = now()
     WHERE p.id = OLD.product_id AND p.stock_quantity IS NOT NULL;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS hylar_release_stock_after_order_item_delete ON public.order_items;
CREATE TRIGGER hylar_release_stock_after_order_item_delete
AFTER DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.hylar_release_stock_on_item_delete();

COMMIT;

-- Validation queries to run after migration, in the correct Hylar project:
-- SELECT id, name, in_stock, stock_quantity FROM public.products ORDER BY name LIMIT 20;
-- SELECT COUNT(*) AS order_items_with_reserved_stock FROM public.order_items WHERE stock_reserved;
-- Confirm expected rejected order and cancellation transitions using TEST orders only.
