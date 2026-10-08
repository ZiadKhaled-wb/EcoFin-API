-- =============================================================================
-- I01 · Stock view (EC-47, D47)
--
-- How much of each product the shop has, and where. Read only (also in an expired, read-only shop),
-- `stock.view`, and only the
-- branches the caller can access (OWNER: all). No table changes.
--
-- list_stock: one row per product and branch.
--   on_hand     sellable stock_levels.on_hand     (kept by app.apply_stock_movement from the ledger)
--   reserved    sellable stock_levels.reserved    (active stock_reservations, S10)
--   available   on_hand - reserved
--   damaged     damaged stock_levels.on_hand      (damaged returns, I02 / S05)
--   in_transit  sent, not yet received transfer lines coming INTO the branch (I03); the stock has
--               already left the source branch (transfer_out), so it is counted nowhere else
--   min_level   the product's min_stock, or the shop's global_min_stock when the product has none
--   low         available < min_level
-- Rows: every active product in every branch in scope (a product with no stock shows zeros, so
-- "low stock" also lists what is missing), plus archived products that still hold stock.
-- Filters: branch, category (with subcategories, D42), search (name / SKU prefix / exact
-- barcode, as C02), low only. Paged; order: product name, then the main branch, then branch code.
--
-- list_stock_movements: the drill-down (newest first, paged) for one product, in one branch or in
-- every branch in scope, with the running balance per branch and stock state. I05 builds the full
-- movement history (filters, serials, export, document links) on top of it.
-- =============================================================================

CREATE FUNCTION public.list_stock(p_branch_id uuid DEFAULT NULL, p_category_id uuid DEFAULT NULL,
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
               COALESCE(lv.on_hand, 0) AS on_hand, COALESCE(lv.reserved, 0) AS reserved,
               COALESCE(lv.on_hand, 0) - COALESCE(lv.reserved, 0) AS available,
               COALESCE(lv.damaged, 0) AS damaged, COALESCE(tr.in_transit, 0) AS in_transit,
               CASE WHEN p.min_stock > 0 THEN p.min_stock ELSE COALESCE(v_global, 0) END AS min_level
        FROM public.products p
        CROSS JOIN public.branches b
        LEFT JOIN lv ON lv.product_id = p.id AND lv.branch_id = b.id
        LEFT JOIN tr ON tr.product_id = p.id AND tr.branch_id = b.id
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
        SELECT r.*, r.available < r.min_level AS low FROM rows r
        WHERE NOT COALESCE(p_low_only, false) OR r.available < r.min_level
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'product_id', f.product_id, 'name_ar', f.name_ar, 'name_en', f.name_en, 'sku', f.sku,
                'barcode', f.barcode, 'category_id', f.category_id, 'is_serialized', f.is_serialized,
                'archived_at', f.archived_at, 'branch_id', f.branch_id,
                'on_hand', f.on_hand, 'reserved', f.reserved, 'available', f.available,
                'damaged', f.damaged, 'in_transit', f.in_transit, 'min_level', f.min_level, 'low', f.low)
                ORDER BY f.name_ar, f.product_id, f.is_main DESC, f.branch_code, f.branch_id)
            FROM (SELECT * FROM found ORDER BY name_ar, product_id, is_main DESC, branch_code, branch_id
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.list_stock_movements(p_product_id uuid, p_branch_id uuid DEFAULT NULL,
                                            p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
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
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
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

    WITH m AS (
        SELECT sm.*,
               sum(sm.quantity) OVER (PARTITION BY sm.branch_id, sm.stock_state
                                      ORDER BY sm.created_at, sm.id) AS balance_after
        FROM public.stock_movements sm
        WHERE sm.organization_id = v_org AND sm.product_id = p_product_id AND sm.branch_id = ANY(v_branches)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', x.id, 'created_at', x.created_at, 'business_date', x.business_date,
                'branch_id', x.branch_id, 'type', x.type, 'stock_state', x.stock_state,
                'quantity', x.quantity, 'balance_after', x.balance_after,
                'serial', u.serial, 'source_type', x.source_type, 'source_id', x.source_id,
                'reverses_movement_id', x.reverses_movement_id, 'created_by_name', e.full_name)
                ORDER BY x.created_at DESC, x.id DESC)
            FROM (SELECT * FROM m ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) x
            LEFT JOIN public.units u ON u.id = x.unit_id AND u.organization_id = x.organization_id
            LEFT JOIN public.employees e ON e.id = x.created_by AND e.organization_id = x.organization_id),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM m))
    INTO v_result;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.list_stock(uuid, uuid, boolean, text, boolean, integer, integer),
    public.list_stock_movements(uuid, uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_stock(uuid, uuid, boolean, text, boolean, integer, integer),
    public.list_stock_movements(uuid, uuid, integer, integer) TO authenticated;
