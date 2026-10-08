-- =============================================================================
-- I06 · Low-stock alerts (EC-52, D52)
--
-- A product is low in a branch when its available stock (on hand − reserved, sellable) is below
-- its min level there. User decision: a branch may override the min level. The level used is
-- the branch's own (0 = never low there), else the product's min_stock (C02) when above 0, else
-- the shop's global_min_stock (P03). An archived product, or any product in a deactivated branch,
-- is never low (neither is restocked).
--
-- product_branch_min_stock: the per-branch overrides (one row per product and branch).
-- set_branch_min_level: sets or removes one override (catalog.manage + the branch; audited
--   stock.min_level_set).
-- list_branch_min_levels: a product's level in each of the caller's branches and where it comes
--   from (stock.view).
-- low_stock_summary: the dashboard card (D01): low products per branch and the biggest
--   shortages (stock.view, the caller's branches).
-- list_stock (I01) now uses the same levels and says where each comes from (min_source).
-- The "start a purchase order" button belongs to U05 (user decision). Numbered after main (D39).
-- =============================================================================

-- 1. Per-branch min levels ------------------------------------------------------------------------------

CREATE TABLE public.product_branch_min_stock (
    organization_id  uuid NOT NULL,
    product_id       uuid NOT NULL,
    branch_id        uuid NOT NULL,
    min_stock        integer NOT NULL CHECK (min_stock BETWEEN 0 AND 1000000),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    PRIMARY KEY (organization_id, product_id, branch_id),
    FOREIGN KEY (product_id, organization_id) REFERENCES public.products (id, organization_id),
    FOREIGN KEY (branch_id, organization_id)  REFERENCES public.branches (id, organization_id),
    FOREIGN KEY (updated_by, organization_id) REFERENCES public.employees (id, organization_id)
);
ALTER TABLE public.product_branch_min_stock ENABLE ROW LEVEL SECURITY;
CREATE POLICY product_branch_min_stock_tenant_read ON public.product_branch_min_stock
    FOR SELECT TO authenticated USING (organization_id = (SELECT app.current_org_id()));
REVOKE ALL ON public.product_branch_min_stock FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.product_branch_min_stock TO authenticated;
GRANT ALL ON public.product_branch_min_stock TO service_role;

-- The level in use: the branch's own, else the product's (when above 0), else the shop's.
CREATE FUNCTION app.stock_min_level(p_branch_min integer, p_product_min integer, p_shop_min integer)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT COALESCE(p_branch_min, CASE WHEN p_product_min > 0 THEN p_product_min ELSE COALESCE(p_shop_min, 0) END)
$$;
CREATE FUNCTION app.stock_min_source(p_branch_min integer, p_product_min integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE WHEN p_branch_min IS NOT NULL THEN 'branch' WHEN p_product_min > 0 THEN 'product' ELSE 'shop' END
$$;

-- A product's levels in the caller's branches (the product page and the set reply).
CREATE FUNCTION app.branch_min_levels_json(p_org uuid, p_product_id uuid, p_branches uuid[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'product_id', p.id, 'product_min_stock', p.min_stock, 'shop_min_stock', COALESCE(s.global_min_stock, 0),
        'branches', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'branch_id', b.id, 'min_stock', bm.min_stock,
                'min_level', app.stock_min_level(bm.min_stock, p.min_stock, s.global_min_stock),
                'min_source', app.stock_min_source(bm.min_stock, p.min_stock))
                ORDER BY b.is_main DESC, b.code, b.id)
            FROM public.branches b
            LEFT JOIN public.product_branch_min_stock bm
                   ON bm.organization_id = p_org AND bm.product_id = p.id AND bm.branch_id = b.id
            WHERE b.organization_id = p_org AND b.id = ANY(p_branches)), '[]'::jsonb))
    FROM public.products p
    LEFT JOIN public.org_settings s ON s.organization_id = p.organization_id
    WHERE p.organization_id = p_org AND p.id = p_product_id
$$;

CREATE FUNCTION public.list_branch_min_levels(p_product_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[];
BEGIN
    -- A read: works in a read-only (expired) shop too, so app.has_permission, not require_permission.
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
    FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    RETURN app.branch_min_levels_json(v_org, p_product_id, v_branches);
END;
$$;

-- Sets the product's min level in one branch, or removes it (NULL: back to the product's / shop's).
CREATE FUNCTION public.set_branch_min_level(p_product_id uuid, p_branch_id uuid, p_min_stock integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_before integer; v_branches uuid[];
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p_min_stock IS NOT NULL AND (p_min_stock < 0 OR p_min_stock > 1000000) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: min_stock' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);

    SELECT bm.min_stock INTO v_before FROM public.product_branch_min_stock bm
    WHERE bm.organization_id = v_org AND bm.product_id = p_product_id AND bm.branch_id = p_branch_id;
    IF p_min_stock IS NULL THEN
        DELETE FROM public.product_branch_min_stock bm
        WHERE bm.organization_id = v_org AND bm.product_id = p_product_id AND bm.branch_id = p_branch_id;
    ELSE
        INSERT INTO public.product_branch_min_stock (organization_id, product_id, branch_id, min_stock, updated_by)
        VALUES (v_org, p_product_id, p_branch_id, p_min_stock, v_emp)
        ON CONFLICT (organization_id, product_id, branch_id)
        DO UPDATE SET min_stock = EXCLUDED.min_stock, updated_at = now(), updated_by = EXCLUDED.updated_by;
    END IF;

    PERFORM app.write_audit('stock.min_level_set', 'product', p_product_id,
        jsonb_build_object('branch_id', p_branch_id, 'min_stock', v_before),
        jsonb_build_object('branch_id', p_branch_id, 'min_stock', p_min_stock),
        NULL, p_branch_id);
    SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
    FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    RETURN app.branch_min_levels_json(v_org, p_product_id, v_branches);
END;
$$;

-- 2. The stock view (I01) uses the same levels ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_stock(p_branch_id uuid DEFAULT NULL, p_category_id uuid DEFAULT NULL,
                                             p_include_children boolean DEFAULT true, p_search text DEFAULT NULL,
                                             p_low_only boolean DEFAULT false,
                                             p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_search text; v_like text; v_cats uuid[]; v_branches uuid[]; v_global integer;
    v_result jsonb;
BEGIN
    -- A read: works in a read-only (expired) shop too, so app.has_permission, not require_permission.
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');

    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;
    IF p_category_id IS NOT NULL THEN
        v_cats := CASE WHEN COALESCE(p_include_children, true)
                       THEN app.category_with_children(v_org, p_category_id)
                       ELSE ARRAY[p_category_id] END;
    END IF;
    SELECT s.global_min_stock INTO v_global FROM public.org_settings s WHERE s.organization_id = v_org;

    WITH lv AS (
        SELECT l.product_id, l.branch_id,
               COALESCE(sum(l.on_hand) FILTER (WHERE l.stock_state = 'sellable'), 0)::integer AS on_hand,
               COALESCE(sum(l.reserved) FILTER (WHERE l.stock_state = 'sellable'), 0)::integer AS reserved,
               COALESCE(sum(l.on_hand) FILTER (WHERE l.stock_state = 'damaged'), 0)::integer AS damaged
        FROM public.stock_levels l
        WHERE l.organization_id = v_org AND l.branch_id = ANY(v_branches)
        GROUP BY l.product_id, l.branch_id
    ), tr AS (
        SELECT tl.product_id, t.to_branch_id AS branch_id, sum(tl.qty_sent)::integer AS in_transit
        FROM public.stock_transfer_lines tl
        JOIN public.stock_transfers t ON t.id = tl.transfer_id AND t.organization_id = tl.organization_id
        WHERE tl.organization_id = v_org AND t.status = 'sent' AND t.to_branch_id = ANY(v_branches)
        GROUP BY tl.product_id, t.to_branch_id
    ), rows AS (
        SELECT p.id AS product_id, p.name_ar, p.name_en, p.sku, p.barcode, p.category_id,
               p.is_serialized, p.archived_at, b.id AS branch_id, b.code AS branch_code, b.is_main,
               b.is_active AS branch_active,
               COALESCE(lv.on_hand, 0) AS on_hand, COALESCE(lv.reserved, 0) AS reserved,
               COALESCE(lv.on_hand, 0) - COALESCE(lv.reserved, 0) AS available,
               COALESCE(lv.damaged, 0) AS damaged, COALESCE(tr.in_transit, 0) AS in_transit,
               app.stock_min_level(bm.min_stock, p.min_stock, v_global) AS min_level,
               app.stock_min_source(bm.min_stock, p.min_stock) AS min_source
        FROM public.products p
        CROSS JOIN public.branches b
        LEFT JOIN lv ON lv.product_id = p.id AND lv.branch_id = b.id
        LEFT JOIN tr ON tr.product_id = p.id AND tr.branch_id = b.id
        LEFT JOIN public.product_branch_min_stock bm
               ON bm.organization_id = v_org AND bm.product_id = p.id AND bm.branch_id = b.id
        WHERE p.organization_id = v_org AND b.organization_id = v_org AND b.id = ANY(v_branches)
          AND (p.archived_at IS NULL
               OR COALESCE(lv.on_hand, 0) <> 0 OR COALESCE(lv.reserved, 0) <> 0
               OR COALESCE(lv.damaged, 0) <> 0 OR COALESCE(tr.in_transit, 0) <> 0)
          AND (v_cats IS NULL OR p.category_id = ANY(v_cats))
          AND (v_search IS NULL
               OR p.name_ar ILIKE '%' || v_like || '%'
               OR p.name_en ILIKE '%' || v_like || '%'
               OR p.sku ILIKE v_like || '%'
               OR p.barcode = v_search)
    ), found AS (
        SELECT r.*, (r.archived_at IS NULL AND r.branch_active AND r.available < r.min_level) AS low FROM rows r
        WHERE NOT COALESCE(p_low_only, false)
           OR (r.archived_at IS NULL AND r.branch_active AND r.available < r.min_level)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'product_id', f.product_id, 'name_ar', f.name_ar, 'name_en', f.name_en, 'sku', f.sku,
                'barcode', f.barcode, 'category_id', f.category_id, 'is_serialized', f.is_serialized,
                'archived_at', f.archived_at, 'branch_id', f.branch_id,
                'on_hand', f.on_hand, 'reserved', f.reserved, 'available', f.available,
                'damaged', f.damaged, 'in_transit', f.in_transit, 'min_level', f.min_level,
                'min_source', f.min_source, 'low', f.low)
                ORDER BY f.name_ar, f.product_id, f.is_main DESC, f.branch_code, f.branch_id)
            FROM (SELECT * FROM found ORDER BY name_ar, product_id, is_main DESC, branch_code, branch_id
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 3. The dashboard card ---------------------------------------------------------------------------------

-- How many products are low in each of the caller's active branches, and the p_limit biggest shortages
-- (min level − available), then by name.
CREATE FUNCTION public.low_stock_summary(p_limit integer DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_global integer; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: limit' USING ERRCODE = 'P0001';
    END IF;
    v_org := app.current_org_id();
    SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
    FROM public.branches b WHERE b.organization_id = v_org AND b.is_active AND app.has_branch_access(b.id);
    SELECT s.global_min_stock INTO v_global FROM public.org_settings s WHERE s.organization_id = v_org;

    WITH lv AS (
        SELECT l.product_id, l.branch_id, (l.on_hand - l.reserved)::integer AS available
        FROM public.stock_levels l
        WHERE l.organization_id = v_org AND l.branch_id = ANY(v_branches) AND l.stock_state = 'sellable'
    ), low AS (
        SELECT p.id AS product_id, p.name_ar, p.name_en, p.sku, b.id AS branch_id,
               COALESCE(lv.available, 0) AS available,
               app.stock_min_level(bm.min_stock, p.min_stock, v_global) AS min_level
        FROM public.products p
        CROSS JOIN public.branches b
        LEFT JOIN lv ON lv.product_id = p.id AND lv.branch_id = b.id
        LEFT JOIN public.product_branch_min_stock bm
               ON bm.organization_id = v_org AND bm.product_id = p.id AND bm.branch_id = b.id
        WHERE p.organization_id = v_org AND p.archived_at IS NULL
          AND b.organization_id = v_org AND b.id = ANY(v_branches)
          AND COALESCE(lv.available, 0) < app.stock_min_level(bm.min_stock, p.min_stock, v_global)
    )
    SELECT jsonb_build_object(
        'total', (SELECT count(*) FROM low),
        'branches', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('branch_id', b.id,
                                                'low', (SELECT count(*) FROM low WHERE low.branch_id = b.id))
                             ORDER BY b.is_main DESC, b.code, b.id)
            FROM public.branches b WHERE b.organization_id = v_org AND b.id = ANY(v_branches)), '[]'::jsonb),
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'product_id', x.product_id, 'name_ar', x.name_ar, 'name_en', x.name_en, 'sku', x.sku,
                'branch_id', x.branch_id, 'available', x.available, 'min_level', x.min_level,
                'shortage', x.min_level - x.available)
                ORDER BY x.min_level - x.available DESC, x.name_ar, x.product_id, x.branch_id)
            FROM (SELECT * FROM low ORDER BY min_level - available DESC, name_ar, product_id, branch_id
                  LIMIT p_limit) x), '[]'::jsonb))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 4. Grants ----------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.stock_min_level(integer, integer, integer), app.stock_min_source(integer, integer),
    app.branch_min_levels_json(uuid, uuid, uuid[])
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_branch_min_levels(uuid), public.set_branch_min_level(uuid, uuid, integer),
    public.low_stock_summary(integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_branch_min_levels(uuid), public.set_branch_min_level(uuid, uuid, integer),
    public.low_stock_summary(integer)
    TO authenticated;
