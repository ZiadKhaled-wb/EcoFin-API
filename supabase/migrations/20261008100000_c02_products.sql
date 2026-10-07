-- =============================================================================
-- C02 · Products (EC-43, D44)
--
-- Add, edit, archive and restore the products a shop sells. Every employee can search and read
-- the catalog; the POS finds an ACTIVE product by barcode or SKU (lookup_product). Writes need
-- catalog.manage; changing the price of an existing product also needs catalog.price_change.
-- Every write that changes something writes exactly one audit row (D19).
--
-- Numbered after the newest migration on main (D39). Everything below is NEW: the baseline's
-- products table, its UNIQUE (organization_id, sku), the partial unique barcode index, the
-- composite FKs, the trigram indexes, the RLS tenant policy and the triggers stay as they are.
--
-- Rules (D44):
--   * avg_cost is never writable here (purchase approval owns it); a body with it is refused.
--   * is_active moves together with archived_at (archive: false + now(); restore: true + NULL).
--   * An empty or null barcode is generated: an in-store EAN-13, '2' + 11 random digits + the
--     check digit (app.ean13_check_digit); a collision retries with new digits up to 5 times.
--   * is_serialized is locked once the product has a units row or a stock_movements row.
-- =============================================================================

-- 1. Helpers (no grants) ------------------------------------------------------------------------

-- EAN-13 check digit of the first 12 digits: weights 1,3,1,3,... from the left.
CREATE FUNCTION app.ean13_check_digit(p_digits text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_sum integer := 0; i integer;
BEGIN
    IF p_digits IS NULL OR p_digits !~ '^[0-9]{12}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: ean13' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..12 LOOP
        v_sum := v_sum + substr(p_digits, i, 1)::integer * CASE WHEN i % 2 = 0 THEN 3 ELSE 1 END;
    END LOOP;
    RETURN ((10 - v_sum % 10) % 10)::text;
END;
$$;

-- A fresh in-store code: '2' + 11 random digits + check digit.
CREATE FUNCTION app.generate_product_barcode()
RETURNS text LANGUAGE plpgsql VOLATILE SET search_path = ''
AS $$
DECLARE v_body text;
BEGIN
    v_body := '2' || lpad(floor(random() * 100000000000)::bigint::text, 11, '0');
    RETURN v_body || app.ean13_check_digit(v_body);
END;
$$;

-- Row shape of the contract's Product (also the audit before/after). Money and cost as strings.
CREATE FUNCTION app.product_json(p public.products)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', p.id, 'name_ar', p.name_ar, 'name_en', p.name_en, 'sku', p.sku, 'barcode', p.barcode,
        'category_id', p.category_id, 'unit_of_measure', p.unit_of_measure,
        'cash_price', p.cash_price::text, 'installment_price', p.installment_price::text,
        'avg_cost', p.avg_cost::text, 'tax_class_id', p.tax_class_id,
        'warranty_months', p.warranty_months, 'is_serialized', p.is_serialized,
        'min_stock', p.min_stock, 'image_file_id', p.image_file_id,
        'eta_item_code', p.eta_item_code, 'eta_item_type', p.eta_item_type,
        'archived_at', p.archived_at, 'created_at', p.created_at, 'updated_at', p.updated_at)
$$;

-- Applies the keys of c to the row r and validates them; the shared rules of create and update.
-- An empty or null barcode comes back as NULL: the caller generates one.
-- VOLATILE: it takes FOR SHARE locks on the category and tax class it accepts.
CREATE FUNCTION app.product_apply(p_org uuid, r public.products, c jsonb)
RETURNS public.products LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
    v_key text; v_txt text; v_num numeric; v_int integer; v_id uuid;
    v_cat public.categories%ROWTYPE;
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    -- avg_cost, organization_id, is_active, archived_at and anything unknown are refused.
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (ARRAY['name_ar', 'name_en', 'sku', 'barcode', 'category_id', 'unit_of_measure',
        'cash_price', 'installment_price', 'tax_class_id', 'warranty_months', 'is_serialized',
        'min_stock', 'image_file_id', 'eta_item_code', 'eta_item_type']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;

    IF c ? 'name_ar' THEN
        v_txt := btrim(c ->> 'name_ar');
        IF v_txt IS NULL OR length(v_txt) < 1 OR length(v_txt) > 150 THEN
            RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        r.name_ar := v_txt;
    END IF;
    IF c ? 'name_en' THEN
        v_txt := NULLIF(btrim(c ->> 'name_en'), '');
        IF length(v_txt) > 150 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: name_en' USING ERRCODE = 'P0001';
        END IF;
        r.name_en := v_txt;
    END IF;
    IF c ? 'sku' THEN
        v_txt := upper(btrim(c ->> 'sku'));
        IF v_txt IS NULL OR length(v_txt) < 1 OR length(v_txt) > 40 OR v_txt !~ '^[A-Z0-9._/-]+$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: sku' USING ERRCODE = 'P0001';
        END IF;
        r.sku := v_txt;
    END IF;
    IF c ? 'barcode' THEN
        v_txt := NULLIF(btrim(c ->> 'barcode'), '');
        IF v_txt IS NOT NULL AND (length(v_txt) < 4 OR length(v_txt) > 32 OR v_txt !~ '^[0-9A-Za-z-]+$') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: barcode' USING ERRCODE = 'P0001';
        END IF;
        r.barcode := v_txt;
    END IF;
    IF c ? 'category_id' THEN
        IF jsonb_typeof(c -> 'category_id') = 'null' THEN
            r.category_id := NULL;
        ELSE
            v_id := (c ->> 'category_id')::uuid;
            -- FOR SHARE: a concurrent category archive (FOR UPDATE) waits, or we see it archived.
            SELECT * INTO v_cat FROM public.categories
            WHERE id = v_id AND organization_id = p_org FOR SHARE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_cat.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED' USING ERRCODE = 'P0001';
            END IF;
            r.category_id := v_id;
        END IF;
    END IF;
    IF c ? 'unit_of_measure' THEN
        v_txt := btrim(c ->> 'unit_of_measure');
        IF v_txt IS NULL OR length(v_txt) < 1 OR length(v_txt) > 20 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unit_of_measure' USING ERRCODE = 'P0001';
        END IF;
        r.unit_of_measure := v_txt;
    END IF;
    IF c ? 'cash_price' THEN
        v_num := (c ->> 'cash_price')::numeric;
        IF v_num IS NULL OR v_num < 0 OR v_num <> round(v_num, 2) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: cash_price' USING ERRCODE = 'P0001';
        END IF;
        r.cash_price := v_num;
    END IF;
    IF c ? 'installment_price' THEN
        v_num := (c ->> 'installment_price')::numeric;
        IF v_num < 0 OR v_num <> round(v_num, 2) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: installment_price' USING ERRCODE = 'P0001';
        END IF;
        r.installment_price := v_num;                  -- NULL = cash price + policy markup
    END IF;
    IF c ? 'tax_class_id' THEN
        v_id := (c ->> 'tax_class_id')::uuid;
        IF v_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM public.tax_classes t
            WHERE t.id = v_id AND t.organization_id = p_org AND t.archived_at IS NULL FOR SHARE) THEN
            RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        r.tax_class_id := v_id;
    END IF;
    IF c ? 'warranty_months' THEN
        v_num := (c ->> 'warranty_months')::numeric;
        IF v_num IS NULL OR v_num <> trunc(v_num) OR v_num < 0 OR v_num > 120 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: warranty_months' USING ERRCODE = 'P0001';
        END IF;
        r.warranty_months := v_num::integer;
    END IF;
    IF c ? 'is_serialized' THEN
        IF jsonb_typeof(c -> 'is_serialized') <> 'boolean' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: is_serialized' USING ERRCODE = 'P0001';
        END IF;
        r.is_serialized := (c ->> 'is_serialized')::boolean;
    END IF;
    IF c ? 'min_stock' THEN
        v_num := (c ->> 'min_stock')::numeric;
        IF v_num IS NULL OR v_num <> trunc(v_num) OR v_num < 0 OR v_num > 1000000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: min_stock' USING ERRCODE = 'P0001';
        END IF;
        r.min_stock := v_num::integer;
    END IF;
    IF c ? 'image_file_id' THEN
        IF jsonb_typeof(c -> 'image_file_id') = 'null' THEN
            r.image_file_id := NULL;
        ELSE
            v_id := (c ->> 'image_file_id')::uuid;
            IF NOT EXISTS (SELECT 1 FROM public.files f
                           WHERE f.id = v_id AND f.organization_id = p_org AND f.purpose = 'product_image') THEN
                RAISE EXCEPTION 'FILE_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            r.image_file_id := v_id;
        END IF;
    END IF;
    IF c ? 'eta_item_code' THEN
        v_txt := NULLIF(btrim(c ->> 'eta_item_code'), '');
        IF length(v_txt) > 40 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: eta_item_code' USING ERRCODE = 'P0001';
        END IF;
        r.eta_item_code := v_txt;
    END IF;
    IF c ? 'eta_item_type' THEN
        v_txt := c ->> 'eta_item_type';
        IF v_txt IS NOT NULL AND v_txt NOT IN ('EGS', 'GS1') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: eta_item_type' USING ERRCODE = 'P0001';
        END IF;
        r.eta_item_type := v_txt;
    END IF;
    -- Both or neither.
    IF (r.eta_item_code IS NULL) <> (r.eta_item_type IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: eta_item' USING ERRCODE = 'P0001';
    END IF;
    RETURN r;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: product' USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION app.ean13_check_digit(text), app.generate_product_barcode(),
    app.product_json(public.products), app.product_apply(uuid, public.products, jsonb)
    FROM PUBLIC, anon, authenticated;

-- 2. Reads: any signed-in employee (catalog screen, product forms, the POS) ----------------------

CREATE FUNCTION public.list_products(p_search text DEFAULT NULL, p_category_id uuid DEFAULT NULL,
                                     p_include_children boolean DEFAULT true, p_status text DEFAULT 'active',
                                     p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_search text; v_like text; v_cats uuid[]; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF COALESCE(p_status, 'active') NOT IN ('active', 'archived', 'all')
       OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    -- The search text is literal: escape the LIKE wildcards.
    v_like := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');
    IF p_category_id IS NOT NULL THEN
        v_cats := CASE WHEN COALESCE(p_include_children, true)
                       THEN app.category_with_children(v_org, p_category_id)
                       ELSE ARRAY[p_category_id] END;
    END IF;

    WITH found AS (
        SELECT p.id, p.name_ar, app.product_json(p) AS j FROM public.products p
        WHERE p.organization_id = v_org
          AND CASE COALESCE(p_status, 'active')
                WHEN 'active' THEN p.archived_at IS NULL
                WHEN 'archived' THEN p.archived_at IS NOT NULL
                ELSE true END
          AND (v_cats IS NULL OR p.category_id = ANY(v_cats))
          AND (v_search IS NULL
               OR p.name_ar ILIKE '%' || v_like || '%'
               OR p.name_en ILIKE '%' || v_like || '%'
               OR p.sku ILIKE v_like || '%'
               OR p.barcode = v_search)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(pg.j ORDER BY pg.name_ar, pg.id)
            FROM (SELECT f.* FROM found f ORDER BY f.name_ar, f.id LIMIT p_limit OFFSET p_offset) pg), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Archived included: old documents keep showing the product.
CREATE FUNCTION public.get_product(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_json jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    SELECT app.product_json(p) INTO v_json FROM public.products p
    WHERE p.id = p_id AND p.organization_id = app.current_org_id();
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- The POS: exact barcode first, then exact SKU (upper-cased). ACTIVE products only.
CREATE FUNCTION public.lookup_product(p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_code text; v_json jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    v_code := btrim(p_code);
    IF v_code IS NULL OR length(v_code) < 1 OR length(v_code) > 64 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: code' USING ERRCODE = 'P0001';
    END IF;
    SELECT app.product_json(p) INTO v_json FROM public.products p
    WHERE p.organization_id = v_org AND p.barcode = v_code AND p.archived_at IS NULL;
    IF v_json IS NULL THEN
        SELECT app.product_json(p) INTO v_json FROM public.products p
        WHERE p.organization_id = v_org AND p.sku = upper(v_code) AND p.archived_at IS NULL;
    END IF;
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- 3. Writes (catalog.manage): create ------------------------------------------------------------

CREATE FUNCTION public.create_product(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; r public.products; v_id uuid; v_generate boolean;
    v_try integer := 0; v_constraint text;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p ? 'name_ar') THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p ? 'sku') OR NOT (p ? 'cash_price') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', CASE WHEN p ? 'sku' THEN 'cash_price' ELSE 'sku' END
            USING ERRCODE = 'P0001';
    END IF;
    -- Defaults (the table's) before the body is applied.
    r.organization_id := v_org;
    r.unit_of_measure := 'piece';
    r.warranty_months := 0;
    r.is_serialized := false;
    r.min_stock := 0;
    IF NOT (p ? 'tax_class_id') THEN
        SELECT s.default_tax_class_id INTO r.tax_class_id FROM public.org_settings s
        WHERE s.organization_id = v_org;
        IF r.tax_class_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM public.tax_classes t
            WHERE t.id = r.tax_class_id AND t.organization_id = v_org AND t.archived_at IS NULL) THEN
            RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    r := app.product_apply(v_org, r, p);

    IF EXISTS (SELECT 1 FROM public.products x WHERE x.organization_id = v_org AND x.sku = r.sku) THEN
        RAISE EXCEPTION 'PRODUCT_SKU_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    v_generate := r.barcode IS NULL;
    IF NOT v_generate AND EXISTS (
        SELECT 1 FROM public.products x WHERE x.organization_id = v_org AND x.barcode = r.barcode) THEN
        RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN' USING ERRCODE = 'P0001';
    END IF;

    LOOP
        IF v_generate THEN
            r.barcode := app.generate_product_barcode();
        END IF;
        BEGIN
            INSERT INTO public.products (organization_id, name_ar, name_en, sku, barcode, category_id,
                unit_of_measure, cash_price, installment_price, avg_cost, tax_class_id, warranty_months,
                is_serialized, min_stock, image_file_id, eta_item_code, eta_item_type, is_active,
                created_by, updated_by)
            VALUES (v_org, r.name_ar, r.name_en, r.sku, r.barcode, r.category_id, r.unit_of_measure,
                r.cash_price, r.installment_price, 0, r.tax_class_id, r.warranty_months, r.is_serialized,
                r.min_stock, r.image_file_id, r.eta_item_code, r.eta_item_type, true, v_emp, v_emp)
            RETURNING id INTO v_id;
            EXIT;
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            IF v_constraint = 'products_sku_key' THEN
                RAISE EXCEPTION 'PRODUCT_SKU_TAKEN' USING ERRCODE = 'P0001';
            END IF;
            v_try := v_try + 1;
            IF NOT v_generate OR v_try >= 5 THEN       -- a given code taken in a race, or no luck
                RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN' USING ERRCODE = 'P0001';
            END IF;
        END;
    END LOOP;

    PERFORM app.write_audit('product.created', 'product', v_id,
        p_after => (SELECT app.product_json(x) FROM public.products x WHERE x.id = v_id));
    RETURN v_id;
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: product' USING ERRCODE = 'P0001';
END;
$$;

-- 4. Writes: partial update -----------------------------------------------------------------------
-- A price change (cash or installment) also needs catalog.price_change and is audited as
-- product.price_changed; anything else as product.updated. Before/after hold the changed keys.

CREATE FUNCTION public.update_product(p_id uuid, p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.products; r public.products; v_generate boolean;
    v_try integer := 0; v_constraint text; v_before jsonb; v_after jsonb; v_old_json jsonb;
    v_new_json jsonb; v_price_changed boolean;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.products
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND OR v_old.archived_at IS NOT NULL THEN  -- archived: restore it first
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    r := app.product_apply(v_org, v_old, p_changes);
    -- Setting the barcode to empty or null asks for a new generated one.
    v_generate := p_changes ? 'barcode' AND r.barcode IS NULL;
    IF NOT v_generate THEN
        r.barcode := COALESCE(r.barcode, v_old.barcode);
    END IF;

    v_price_changed := r.cash_price IS DISTINCT FROM v_old.cash_price
                    OR r.installment_price IS DISTINCT FROM v_old.installment_price;
    IF NOT v_generate AND NOT v_price_changed
       AND app.product_json(r) = app.product_json(v_old) THEN
        RETURN;                                      -- no change: no update, no audit row
    END IF;
    IF v_price_changed THEN
        PERFORM app.require_permission('catalog.price_change');
    END IF;

    IF r.sku IS DISTINCT FROM v_old.sku AND EXISTS (
        SELECT 1 FROM public.products x WHERE x.organization_id = v_org AND x.sku = r.sku AND x.id <> p_id) THEN
        RAISE EXCEPTION 'PRODUCT_SKU_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_generate AND r.barcode IS DISTINCT FROM v_old.barcode AND EXISTS (
        SELECT 1 FROM public.products x WHERE x.organization_id = v_org AND x.barcode = r.barcode AND x.id <> p_id) THEN
        RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    IF r.is_serialized IS DISTINCT FROM v_old.is_serialized AND (
        EXISTS (SELECT 1 FROM public.units u WHERE u.organization_id = v_org AND u.product_id = p_id)
        OR EXISTS (SELECT 1 FROM public.stock_movements m WHERE m.organization_id = v_org AND m.product_id = p_id)) THEN
        RAISE EXCEPTION 'PRODUCT_SERIAL_LOCKED' USING ERRCODE = 'P0001';
    END IF;

    LOOP
        IF v_generate THEN
            r.barcode := app.generate_product_barcode();
        END IF;
        BEGIN
            UPDATE public.products SET
                name_ar = r.name_ar, name_en = r.name_en, sku = r.sku, barcode = r.barcode,
                category_id = r.category_id, unit_of_measure = r.unit_of_measure,
                cash_price = r.cash_price, installment_price = r.installment_price,
                tax_class_id = r.tax_class_id, warranty_months = r.warranty_months,
                is_serialized = r.is_serialized, min_stock = r.min_stock,
                image_file_id = r.image_file_id, eta_item_code = r.eta_item_code,
                eta_item_type = r.eta_item_type, updated_by = v_emp
            WHERE id = p_id;
            EXIT;
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            IF v_constraint = 'products_sku_key' THEN
                RAISE EXCEPTION 'PRODUCT_SKU_TAKEN' USING ERRCODE = 'P0001';
            END IF;
            v_try := v_try + 1;
            IF NOT v_generate OR v_try >= 5 THEN
                RAISE EXCEPTION 'PRODUCT_BARCODE_TAKEN' USING ERRCODE = 'P0001';
            END IF;
        END;
    END LOOP;

    v_old_json := app.product_json(v_old);
    SELECT app.product_json(x) INTO v_new_json FROM public.products x WHERE x.id = p_id;
    SELECT jsonb_object_agg(k, v_old_json -> k), jsonb_object_agg(k, v_new_json -> k)
    INTO v_before, v_after
    FROM jsonb_object_keys(v_new_json) k
    WHERE k NOT IN ('updated_at', 'created_at') AND (v_old_json -> k) IS DISTINCT FROM (v_new_json -> k);
    PERFORM app.write_audit(CASE WHEN v_price_changed THEN 'product.price_changed' ELSE 'product.updated' END,
        'product', p_id, p_before => v_before, p_after => v_after);
EXCEPTION
    WHEN check_violation OR not_null_violation OR invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: product' USING ERRCODE = 'P0001';
END;
$$;

-- 5. Writes: archive and restore ----------------------------------------------------------------
-- Archive is allowed with stock on hand (the client asks first). Restore is refused under an
-- archived category (PRODUCT_CATEGORY_ARCHIVED) or with an archived tax class (TAX_CLASS_NOT_FOUND).

CREATE FUNCTION public.set_product_archived(p_id uuid, p_archived boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_old public.products;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.products
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF (v_old.archived_at IS NOT NULL) = p_archived THEN
        RETURN;                                      -- same state: nothing, no audit row
    END IF;

    IF NOT p_archived THEN
        IF v_old.category_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.categories c
            WHERE c.id = v_old.category_id AND c.organization_id = v_org AND c.archived_at IS NOT NULL
            FOR SHARE) THEN
            RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.tax_classes t
                   WHERE t.id = v_old.tax_class_id AND t.organization_id = v_org AND t.archived_at IS NOT NULL
                   FOR SHARE) THEN
            RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE public.products SET
        archived_at = CASE WHEN p_archived THEN now() END,
        is_active = NOT p_archived,
        updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit(CASE WHEN p_archived THEN 'product.archived' ELSE 'product.restored' END,
        'product', p_id,
        p_before => jsonb_build_object('archived_at', v_old.archived_at),
        p_after => (SELECT jsonb_build_object('archived_at', x.archived_at) FROM public.products x WHERE x.id = p_id),
        p_severity => CASE WHEN p_archived THEN 'warning' ELSE 'info' END::public.audit_severity);
END;
$$;

REVOKE ALL ON FUNCTION public.list_products(text, uuid, boolean, text, integer, integer),
    public.get_product(uuid), public.lookup_product(text), public.create_product(jsonb),
    public.update_product(uuid, jsonb), public.set_product_archived(uuid, boolean)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_products(text, uuid, boolean, text, integer, integer),
    public.get_product(uuid), public.lookup_product(text), public.create_product(jsonb),
    public.update_product(uuid, jsonb), public.set_product_archived(uuid, boolean)
    TO authenticated;
