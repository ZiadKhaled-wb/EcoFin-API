-- =============================================================================
-- I05 · Movement history (EC-51, D51)
--
-- Every stock movement for a product, a branch or a serial: date, type, quantity, running
-- balance, who, and the source document (number, other party, adjustment reason, I04's
-- app.stock_source_json). No table changes.
--
-- list_stock_movements (I01's drill-down, D47) is extended, not duplicated: the product becomes
-- optional and it gains the serial, type and date filters. Its first four parameters keep their
-- order, so the I01 calls (product, branch, limit, offset) still work.
-- export_stock_movements: the same rows (newest first, at most 10 000) for a CSV made by the
-- website. User decision: it needs export.data on top of stock.view, and every export is audited
-- (stock_movements.exported, with the filters and the row count). export.data is the one key
-- app.require_permission lets through in an expired shop (P05), so a shop can still take its
-- history out.
--
-- Scope: stock.view, and only the branches the caller can access (OWNER: all); another shop's
-- product or branch is not found. Running balance: the on-hand of that product, branch and stock
-- state after the movement, over the WHOLE ledger (filters by serial, type or date never change
-- it). Reads use app.has_permission, so an expired shop can still read. Numbered after main (D39).
-- =============================================================================

-- 1. The rows -----------------------------------------------------------------------------------------

-- Checks the filters and returns the matching movements with their running balance (unordered).
-- The caller has already checked stock.view.
CREATE FUNCTION app.stock_movement_history(p_org uuid, p_product_id uuid, p_branch_id uuid, p_serial text,
                                           p_types public.stock_movement_type[], p_from date, p_to date)
RETURNS TABLE (out_id uuid, out_created_at timestamptz, out_balance integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_branches uuid[]; v_serial text; v_unit uuid; v_unit_product uuid; v_types public.stock_movement_type[];
BEGIN
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: dates' USING ERRCODE = 'P0001';
    END IF;
    IF p_product_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = p_org) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = p_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = p_org AND app.has_branch_access(b.id);
    END IF;
    -- A serial is matched exactly, as stored (trimmed, upper-cased, I04). An unknown one finds nothing.
    IF p_serial IS NOT NULL THEN
        v_serial := upper(btrim(p_serial));
        IF length(v_serial) NOT BETWEEN 1 AND 64 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: serial' USING ERRCODE = 'P0001';
        END IF;
        SELECT u.id, u.product_id INTO v_unit, v_unit_product
        FROM public.units u WHERE u.organization_id = p_org AND u.serial = v_serial;
        IF NOT FOUND OR (p_product_id IS NOT NULL AND v_unit_product <> p_product_id) THEN
            RETURN;
        END IF;
    END IF;
    IF cardinality(p_types) > 0 THEN
        v_types := p_types;
    END IF;

    -- The balance runs over every movement of the product, branch and state; the serial, type and
    -- date filters apply after it.
    RETURN QUERY
    SELECT h.id, h.created_at, h.balance::integer
    FROM (SELECT sm.id, sm.created_at, sm.unit_id, sm.type, sm.business_date,
                 sum(sm.quantity) OVER (PARTITION BY sm.product_id, sm.branch_id, sm.stock_state
                                        ORDER BY sm.created_at, sm.id) AS balance
          FROM public.stock_movements sm
          WHERE sm.organization_id = p_org AND sm.branch_id = ANY(v_branches)
            AND (COALESCE(p_product_id, v_unit_product) IS NULL
                 OR sm.product_id = COALESCE(p_product_id, v_unit_product))) h
    WHERE (v_unit IS NULL OR h.unit_id = v_unit)
      AND (v_types IS NULL OR h.type = ANY(v_types))
      AND (p_from IS NULL OR h.business_date >= p_from)
      AND (p_to IS NULL OR h.business_date <= p_to);
END;
$$;

-- One movement as the history shows it: product, serial, employee and source document.
CREATE FUNCTION app.stock_movement_item(p_org uuid, p_id uuid, p_balance integer)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', m.id, 'created_at', m.created_at, 'business_date', m.business_date,
        'product_id', m.product_id, 'product_name_ar', p.name_ar, 'product_name_en', p.name_en, 'sku', p.sku,
        'branch_id', m.branch_id, 'unit_id', m.unit_id, 'serial', u.serial,
        'type', m.type, 'stock_state', m.stock_state, 'quantity', m.quantity, 'balance_after', p_balance,
        'source_type', m.source_type, 'source_id', m.source_id,
        'source_number', s.src ->> 'number', 'party', s.src ->> 'party', 'reason', s.src ->> 'reason',
        'reverses_movement_id', m.reverses_movement_id, 'created_by_name', e.full_name)
    FROM public.stock_movements m
    JOIN public.products p ON p.id = m.product_id AND p.organization_id = m.organization_id
    LEFT JOIN public.units u ON u.id = m.unit_id AND u.organization_id = m.organization_id
    LEFT JOIN public.employees e ON e.id = m.created_by AND e.organization_id = m.organization_id
    CROSS JOIN LATERAL (SELECT app.stock_source_json(p_org, m.source_type, m.source_id) AS src) s
    WHERE m.organization_id = p_org AND m.id = p_id
$$;

-- 2. The history (I01's drill-down, extended) -----------------------------------------------------------

DROP FUNCTION public.list_stock_movements(uuid, uuid, integer, integer);

CREATE FUNCTION public.list_stock_movements(p_product_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                            p_limit integer DEFAULT 50, p_offset integer DEFAULT 0,
                                            p_serial text DEFAULT NULL,
                                            p_types public.stock_movement_type[] DEFAULT NULL,
                                            p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_result jsonb;
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

    WITH h AS (
        SELECT * FROM app.stock_movement_history(v_org, p_product_id, p_branch_id, p_serial, p_types, p_from, p_to)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.stock_movement_item(v_org, x.out_id, x.out_balance)
                             ORDER BY x.out_created_at DESC, x.out_id DESC)
            FROM (SELECT * FROM h ORDER BY out_created_at DESC, out_id DESC LIMIT p_limit OFFSET p_offset) x),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM h))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 3. Export ----------------------------------------------------------------------------------------------

CREATE FUNCTION public.export_stock_movements(p_product_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                              p_serial text DEFAULT NULL,
                                              p_types public.stock_movement_type[] DEFAULT NULL,
                                              p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_total integer; v_limit constant integer := 10000; v_result jsonb;
BEGIN
    -- export.data works in an expired shop (P05); a suspended shop is refused.
    PERFORM app.require_permission('export.data');
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();

    -- The items are built only when the rows fit.
    WITH h AS (
        SELECT * FROM app.stock_movement_history(v_org, p_product_id, p_branch_id, p_serial, p_types, p_from, p_to)
    ), c AS (SELECT count(*)::integer AS n FROM h)
    SELECT c.n,
           CASE WHEN c.n <= v_limit THEN jsonb_build_object(
               'items', COALESCE((
                   SELECT jsonb_agg(app.stock_movement_item(v_org, x.out_id, x.out_balance)
                                    ORDER BY x.out_created_at DESC, x.out_id DESC)
                   FROM h x), '[]'::jsonb),
               'total', c.n) END
    INTO v_total, v_result
    FROM c;
    IF v_total > v_limit THEN
        RAISE EXCEPTION 'EXPORT_TOO_LARGE' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('total', v_total, 'limit', v_limit)::text;
    END IF;

    PERFORM app.write_audit('stock_movements.exported', 'stock_movement', NULL, NULL,
        jsonb_build_object('product_id', p_product_id, 'branch_id', p_branch_id,
                           'serial', NULLIF(upper(btrim(p_serial)), ''), 'types', to_jsonb(p_types),
                           'from', p_from, 'to', p_to, 'rows', v_total),
        NULL, p_branch_id);
    RETURN v_result;
END;
$$;

-- 4. Grants ----------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.stock_movement_history(uuid, uuid, uuid, text, public.stock_movement_type[], date, date),
    app.stock_movement_item(uuid, uuid, integer)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
    public.list_stock_movements(uuid, uuid, integer, integer, text, public.stock_movement_type[], date, date),
    public.export_stock_movements(uuid, uuid, text, public.stock_movement_type[], date, date)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
    public.list_stock_movements(uuid, uuid, integer, integer, text, public.stock_movement_type[], date, date),
    public.export_stock_movements(uuid, uuid, text, public.stock_movement_type[], date, date)
    TO authenticated;
