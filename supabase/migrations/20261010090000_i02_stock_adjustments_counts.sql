-- =============================================================================
-- I02 · Stock adjustments and counts (EC-48, D48)
--
-- Corrects stock when the real count differs from the system. Tables are in the baseline
-- (stock_adjustments + lines, stock_counts + lines); this adds the write and read functions.
-- Stock changes only through stock_movements rows (type 'adjustment', source 'stock_adjustment');
-- the baseline triggers keep stock_levels and the unit's status/branch. Sellable stock only.
--
-- Adjustment (stock.adjust): branch, reason, note, lines (product, unit for serialized, ± qty).
--   damage / loss remove stock, found adds it, correction / other either way; other needs a note;
--   'count' is used only by a posted count. One document, numbered SA, posted once (append-only).
-- Count (stock.count): a sheet for a branch, optionally one category (with its subcategories,
--   D42). Lines are snapshotted at creation (non-serialized: one per product; serialized: one per
--   unit in stock or reserved in the branch). People enter counted quantities or scan barcodes /
--   serials; scanning adds a line for a product or unit in scope that wasn't on the sheet.
--   While the count is open, "expected" is the live stock, so the difference shown is what posting
--   will change. Posting locks the stock (product order), stores the expected quantities, and posts
--   every difference as ONE adjustment (reason 'count', linked to the count): afterwards the stock
--   equals the counted numbers. Uncounted lines block posting unless the caller says to treat them
--   as zero (missing). Counts that cover the same products can't be open together in a branch.
-- Reads (list/get) use app.has_permission, so an expired (read-only) shop can still read them.
-- Numbered after the newest migration on main (D39).
-- =============================================================================

-- 1. Helpers --------------------------------------------------------------------------------------

-- Sellable on hand of a product in a branch (0 when there is no level row yet).
CREATE FUNCTION app.sellable_on_hand(p_org uuid, p_product_id uuid, p_branch_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE((SELECT l.on_hand FROM public.stock_levels l
                     WHERE l.organization_id = p_org AND l.product_id = p_product_id
                       AND l.branch_id = p_branch_id AND l.stock_state = 'sellable'), 0)
$$;

-- Lines of a write call: [{product_id, unit_id?, quantity}] (p_kind 'adjust') or
-- [{product_id, unit_id?, counted_qty: int|null}] (p_kind 'count'). 1-500 lines, no duplicates,
-- integers in range. Anything malformed -> VALIDATION_FAILED: lines (never a raw cast error).
CREATE FUNCTION app.stock_lines_parse(p_lines jsonb, p_kind text)
RETURNS TABLE (product_id uuid, unit_id uuid, qty integer)
LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_field text := CASE p_kind WHEN 'adjust' THEN 'quantity' ELSE 'counted_qty' END;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 500
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
                  WHERE jsonb_typeof(e) <> 'object'
                     OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('product_id', 'unit_id', v_field))
                     OR jsonb_typeof(e -> 'product_id') IS DISTINCT FROM 'string'
                     OR COALESCE(jsonb_typeof(e -> 'unit_id'), 'null') NOT IN ('string', 'null')
                     OR (p_kind = 'adjust' AND jsonb_typeof(e -> v_field) IS DISTINCT FROM 'number')
                     OR (p_kind = 'count' AND COALESCE(jsonb_typeof(e -> v_field), 'null') NOT IN ('number', 'null'))) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        RETURN QUERY
        SELECT (e ->> 'product_id')::uuid, NULLIF(e ->> 'unit_id', '')::uuid, (e ->> v_field)::integer
        FROM jsonb_array_elements(p_lines) e;
    EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END;
END;
$$;

-- An adjustment for the API: header, totals and (p_with_lines) its lines.
CREATE FUNCTION app.stock_adjustment_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'number', a.number, 'branch_id', a.branch_id, 'reason', a.reason, 'note', a.note,
        'count_id', a.count_id, 'count_number', c.number, 'created_at', a.created_at,
        'created_by_name', e.full_name,
        'lines_count', (SELECT count(*) FROM public.stock_adjustment_lines l
                        WHERE l.organization_id = p_org AND l.adjustment_id = a.id),
        'quantity_in', (SELECT COALESCE(sum(l.quantity) FILTER (WHERE l.quantity > 0), 0)
                        FROM public.stock_adjustment_lines l
                        WHERE l.organization_id = p_org AND l.adjustment_id = a.id),
        'quantity_out', (SELECT COALESCE(-sum(l.quantity) FILTER (WHERE l.quantity < 0), 0)
                         FROM public.stock_adjustment_lines l
                         WHERE l.organization_id = p_org AND l.adjustment_id = a.id))
        || CASE WHEN p_with_lines THEN jsonb_build_object('lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'sku', p.sku, 'unit_id', l.unit_id, 'serial', u.serial, 'quantity', l.quantity)
                ORDER BY p.name_ar, l.product_id, u.serial)
            FROM public.stock_adjustment_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.adjustment_id = a.id), '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.stock_adjustments a
    LEFT JOIN public.stock_counts c ON c.id = a.count_id AND c.organization_id = a.organization_id
    LEFT JOIN public.employees e ON e.id = a.created_by AND e.organization_id = a.organization_id
    WHERE a.organization_id = p_org AND a.id = p_id
$$;

-- Count lines with the expected quantity: live while the count is open (sellable on hand; for a
-- unit, 1 if it is in stock or reserved in the count's branch), the stored snapshot afterwards.
CREATE FUNCTION app.stock_count_lines_live(p_org uuid, p_count_id uuid)
RETURNS TABLE (line_id uuid, product_id uuid, unit_id uuid, expected integer, counted integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT l.id, l.product_id, l.unit_id,
           CASE WHEN c.status <> 'open' THEN l.expected_qty
                WHEN l.unit_id IS NOT NULL THEN
                    (u.branch_id = c.branch_id AND u.status IN ('in_stock', 'reserved'))::integer
                ELSE COALESCE(sl.on_hand, 0) END,
           l.counted_qty
    FROM public.stock_count_lines l
    JOIN public.stock_counts c ON c.id = l.count_id AND c.organization_id = l.organization_id
    LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
    LEFT JOIN public.stock_levels sl ON sl.organization_id = l.organization_id AND sl.product_id = l.product_id
         AND sl.branch_id = c.branch_id AND sl.stock_state = 'sellable'
    WHERE l.organization_id = p_org AND l.count_id = p_count_id
$$;

-- A count for the API: header and summary (lines, counted, differences, units in / out).
CREATE FUNCTION app.stock_count_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH s AS (
        SELECT count(*) AS lines_total,
               count(*) FILTER (WHERE x.counted IS NOT NULL) AS lines_counted,
               count(*) FILTER (WHERE x.counted IS NOT NULL AND x.counted <> x.expected) AS lines_different,
               COALESCE(sum(x.counted - x.expected) FILTER (WHERE x.counted > x.expected), 0) AS quantity_in,
               COALESCE(sum(x.expected - x.counted) FILTER (WHERE x.counted < x.expected), 0) AS quantity_out
        FROM app.stock_count_lines_live(p_org, p_id) x
    )
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'branch_id', c.branch_id, 'category_id', c.category_id,
        'category_name', cat.name, 'status', c.status, 'created_at', c.created_at,
        'created_by_name', ce.full_name, 'posted_at', c.posted_at, 'posted_by_name', pe.full_name,
        'adjustment_id', a.id, 'adjustment_number', a.number,
        'lines_total', s.lines_total, 'lines_counted', s.lines_counted,
        'lines_different', s.lines_different, 'quantity_in', s.quantity_in, 'quantity_out', s.quantity_out)
    FROM public.stock_counts c
    CROSS JOIN s
    LEFT JOIN public.categories cat ON cat.id = c.category_id AND cat.organization_id = c.organization_id
    LEFT JOIN public.employees ce ON ce.id = c.created_by AND ce.organization_id = c.organization_id
    LEFT JOIN public.employees pe ON pe.id = c.posted_by AND pe.organization_id = c.organization_id
    LEFT JOIN public.stock_adjustments a ON a.count_id = c.id AND a.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_id
$$;

-- One count line for the API.
CREATE FUNCTION app.stock_count_line_json(p_org uuid, p_count_id uuid, p_line_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', x.line_id, 'product_id', x.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
        'sku', p.sku, 'barcode', p.barcode, 'is_serialized', p.is_serialized,
        'unit_id', x.unit_id, 'serial', u.serial, 'expected_qty', x.expected, 'counted_qty', x.counted,
        'difference', x.counted - x.expected)
    FROM app.stock_count_lines_live(p_org, p_count_id) x
    JOIN public.products p ON p.id = x.product_id AND p.organization_id = p_org
    LEFT JOIN public.units u ON u.id = x.unit_id AND u.organization_id = p_org
    WHERE x.line_id = p_line_id
$$;

-- The categories a count covers (NULL = the whole branch).
CREATE FUNCTION app.stock_count_scope(p_org uuid, p_category_id uuid)
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT CASE WHEN p_category_id IS NULL THEN NULL ELSE app.category_with_children(p_org, p_category_id) END
$$;

-- Inserts the lines of an adjustment and their ledger movements, in product_id then unit order
-- (so two documents lock stock rows in the same order). Cost at the time: the unit's cost, else
-- the product's average cost (D04). The triggers raise OUT_OF_STOCK, UNIT_NOT_AVAILABLE,
-- UNIT_ALREADY_IN_STOCK, DAY_CLOSED...
CREATE FUNCTION app.post_adjustment_lines(p_org uuid, p_emp uuid, p_adjustment_id uuid, p_branch_id uuid,
                                          p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_line uuid;
BEGIN
    FOR r IN
        SELECT (e ->> 'product_id')::uuid AS product_id, NULLIF(e ->> 'unit_id', '')::uuid AS unit_id,
               (e ->> 'quantity')::integer AS quantity
        FROM jsonb_array_elements(p_lines) e
        ORDER BY 1, 2 NULLS FIRST
    LOOP
        INSERT INTO public.stock_adjustment_lines (organization_id, adjustment_id, product_id, unit_id, quantity, created_by)
        VALUES (p_org, p_adjustment_id, r.product_id, r.unit_id, r.quantity, p_emp)
        RETURNING id INTO v_line;
        INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                            stock_state, unit_cost, source_type, source_id, source_line_id, created_by)
        SELECT p_org, r.product_id, p_branch_id, r.unit_id, r.quantity, 'adjustment', 'sellable',
               COALESCE(u.cost, p.avg_cost, 0), 'stock_adjustment', p_adjustment_id, v_line, p_emp
        FROM public.products p
        LEFT JOIN public.units u ON u.id = r.unit_id AND u.organization_id = p_org
        WHERE p.id = r.product_id AND p.organization_id = p_org;
    END LOOP;
END;
$$;

-- 2. Adjustments ----------------------------------------------------------------------------------

CREATE FUNCTION public.post_stock_adjustment(p_branch_id uuid, p_reason text, p_note text, p_lines jsonb,
                                             p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_id uuid; v_number text; v_note text; v_bad text; v_lines jsonb;
BEGIN
    v_emp := app.require_permission('stock.adjust');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT a.id INTO v_id FROM public.stock_adjustments a
    WHERE a.organization_id = v_org AND a.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.stock_adjustment_json(v_org, v_id, true);      -- a repeat changes nothing
    END IF;

    IF p_reason IS NULL OR p_reason NOT IN ('damage', 'loss', 'found', 'correction', 'other') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 OR (p_reason = 'other' AND v_note IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);

    SELECT jsonb_agg(jsonb_build_object('product_id', x.product_id, 'unit_id', x.unit_id, 'quantity', x.qty))
    INTO v_lines FROM app.stock_lines_parse(p_lines, 'adjust') x;

    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.quantity IS NULL OR l.quantity = 0 OR abs(l.quantity) > 1000000)
       OR EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
                  GROUP BY l.product_id, l.unit_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE NOT EXISTS (SELECT 1 FROM public.products p
                                 WHERE p.id = l.product_id AND p.organization_id = v_org)) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = v_org
               WHERE p.is_serialized AND l.unit_id IS NULL) THEN
        RAISE EXCEPTION 'UNIT_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = v_org
               WHERE NOT p.is_serialized AND l.unit_id IS NOT NULL) THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.unit_id IS NOT NULL AND NOT EXISTS (
                   SELECT 1 FROM public.units u WHERE u.id = l.unit_id AND u.organization_id = v_org)) THEN
        RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.units u ON u.id = l.unit_id AND u.organization_id = v_org
               WHERE u.product_id <> l.product_id) THEN
        RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.unit_id IS NOT NULL AND abs(l.quantity) <> 1) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    -- The reason says which way stock moves.
    SELECT CASE WHEN p_reason IN ('damage', 'loss') AND bool_or(l.quantity > 0) THEN 'in'
                WHEN p_reason = 'found' AND bool_or(l.quantity < 0) THEN 'out' END
    INTO v_bad FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'ADJUSTMENT_SIGN_INVALID: % can''t move stock %', p_reason, v_bad USING ERRCODE = 'P0001';
    END IF;

    v_number := app.next_document_number(v_org, p_branch_id, 'stock_adjustment');
    INSERT INTO public.stock_adjustments (organization_id, number, branch_id, reason, note, idempotency_key, created_by)
    VALUES (v_org, v_number, p_branch_id, p_reason::public.adjustment_reason, v_note, p_idempotency_key, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.post_adjustment_lines(v_org, v_emp, v_id, p_branch_id, v_lines);

    PERFORM app.write_audit('stock_adjustment.posted', 'stock_adjustment', v_id, NULL,
        jsonb_build_object('number', v_number, 'reason', p_reason, 'note', v_note, 'lines', v_lines),
        v_note, p_branch_id);
    RETURN app.stock_adjustment_json(v_org, v_id, true);
END;
$$;

CREATE FUNCTION public.list_stock_adjustments(p_branch_id uuid DEFAULT NULL, p_reason text DEFAULT NULL,
                                              p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_reason IS NOT NULL AND p_reason NOT IN ('damage', 'loss', 'found', 'correction', 'count', 'other')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
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

    WITH found AS (
        SELECT a.id, a.created_at FROM public.stock_adjustments a
        WHERE a.organization_id = v_org AND a.branch_id = ANY(v_branches)
          AND (p_reason IS NULL OR a.reason::text = p_reason)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.stock_adjustment_json(v_org, f.id, false) ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_stock_adjustment(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT a.branch_id INTO v_branch FROM public.stock_adjustments a WHERE a.id = p_id AND a.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STOCK_ADJUSTMENT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;
    RETURN app.stock_adjustment_json(v_org, p_id, true);
END;
$$;

-- 3. Counts ---------------------------------------------------------------------------------------

CREATE FUNCTION public.create_stock_count(p_branch_id uuid, p_category_id uuid, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid; v_number text; v_scope uuid[]; v_lines integer;
BEGIN
    v_emp := app.require_permission('stock.count');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT c.id INTO v_id FROM public.stock_counts c
    WHERE c.organization_id = v_org AND c.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.stock_count_json(v_org, v_id);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF p_category_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.categories c
        WHERE c.id = p_category_id AND c.organization_id = v_org AND c.archived_at IS NULL) THEN
        RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_scope := app.stock_count_scope(v_org, p_category_id);

    -- One open count per set of products in a branch: two creates for the branch queue here.
    PERFORM pg_advisory_xact_lock(hashtextextended('stock_count/' || v_org::text || '/' || p_branch_id::text, 0));
    IF EXISTS (SELECT 1 FROM public.stock_counts c
               WHERE c.organization_id = v_org AND c.branch_id = p_branch_id AND c.status = 'open'
                 AND (c.category_id IS NULL OR v_scope IS NULL
                      OR app.stock_count_scope(v_org, c.category_id) && v_scope)) THEN
        RAISE EXCEPTION 'STOCK_COUNT_OPEN' USING ERRCODE = 'P0001';
    END IF;

    v_number := app.next_document_number(v_org, p_branch_id, 'stock_count');
    INSERT INTO public.stock_counts (organization_id, number, branch_id, category_id, idempotency_key, created_by, updated_by)
    VALUES (v_org, v_number, p_branch_id, p_category_id, p_idempotency_key, v_emp, v_emp)
    RETURNING id INTO v_id;

    -- The sheet: every product in scope (active, or archived but still holding stock here) ...
    INSERT INTO public.stock_count_lines (organization_id, count_id, product_id, expected_qty, created_by, updated_by)
    SELECT v_org, v_id, p.id, app.sellable_on_hand(v_org, p.id, p_branch_id), v_emp, v_emp
    FROM public.products p
    WHERE p.organization_id = v_org AND NOT p.is_serialized
      AND (v_scope IS NULL OR p.category_id = ANY(v_scope))
      AND (p.archived_at IS NULL OR app.sellable_on_hand(v_org, p.id, p_branch_id) > 0);
    -- ... and every unit of a serialized product in scope that is in this branch.
    INSERT INTO public.stock_count_lines (organization_id, count_id, product_id, unit_id, expected_qty, created_by, updated_by)
    SELECT v_org, v_id, u.product_id, u.id, 1, v_emp, v_emp
    FROM public.units u
    JOIN public.products p ON p.id = u.product_id AND p.organization_id = u.organization_id
    WHERE u.organization_id = v_org AND u.branch_id = p_branch_id AND u.status IN ('in_stock', 'reserved')
      AND (v_scope IS NULL OR p.category_id = ANY(v_scope));
    SELECT count(*) INTO v_lines FROM public.stock_count_lines l WHERE l.organization_id = v_org AND l.count_id = v_id;

    PERFORM app.write_audit('stock_count.created', 'stock_count', v_id, NULL,
        jsonb_build_object('number', v_number, 'category_id', p_category_id, 'lines', v_lines),
        NULL, p_branch_id);
    RETURN app.stock_count_json(v_org, v_id);
END;
$$;

-- Loads a count for a write: the caller's shop, locked, open, in an accessible active branch.
CREATE FUNCTION app.open_stock_count_for_write(p_org uuid, p_count_id uuid)
RETURNS public.stock_counts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_count public.stock_counts;
BEGIN
    SELECT * INTO v_count FROM public.stock_counts c WHERE c.id = p_count_id AND c.organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STOCK_COUNT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_count.branch_id);
    RETURN v_count;
END;
$$;

-- Adds or updates one line of an open count; returns its id. A unit in stock in another branch
-- can't be counted here (that is a transfer); a product or unit outside the count's categories
-- is refused.
CREATE FUNCTION app.stock_count_set_line(p_org uuid, p_emp uuid, p_count public.stock_counts,
                                         p_product_id uuid, p_unit_id uuid, p_counted integer, p_add boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_product public.products; v_unit public.units; v_scope uuid[]; v_line uuid; v_expected integer;
BEGIN
    SELECT * INTO v_product FROM public.products p WHERE p.id = p_product_id AND p.organization_id = p_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_product.is_serialized AND p_unit_id IS NULL THEN
        RAISE EXCEPTION 'UNIT_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_product.is_serialized AND p_unit_id IS NOT NULL THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED' USING ERRCODE = 'P0001';
    END IF;
    IF p_counted IS NOT NULL AND (p_counted < 0 OR p_counted > 1000000 OR (p_unit_id IS NOT NULL AND p_counted > 1)) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: counted_qty' USING ERRCODE = 'P0001';
    END IF;

    SELECT l.id INTO v_line FROM public.stock_count_lines l
    WHERE l.organization_id = p_org AND l.count_id = p_count.id AND l.product_id = p_product_id
      AND l.unit_id IS NOT DISTINCT FROM p_unit_id;
    IF v_line IS NULL THEN
        v_scope := app.stock_count_scope(p_org, p_count.category_id);
        IF v_scope IS NOT NULL AND (v_product.category_id IS NULL OR NOT v_product.category_id = ANY(v_scope)) THEN
            RAISE EXCEPTION 'STOCK_COUNT_PRODUCT_OUT_OF_SCOPE' USING ERRCODE = 'P0001';
        END IF;
        IF p_unit_id IS NOT NULL THEN
            SELECT * INTO v_unit FROM public.units u WHERE u.id = p_unit_id AND u.organization_id = p_org;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_unit.product_id <> p_product_id THEN
                RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
            END IF;
            IF v_unit.status IN ('in_stock', 'reserved', 'in_transit') AND v_unit.branch_id <> p_count.branch_id THEN
                RAISE EXCEPTION 'UNIT_ALREADY_IN_STOCK: % is in another branch', v_unit.serial USING ERRCODE = 'P0001';
            END IF;
            v_expected := (v_unit.branch_id = p_count.branch_id AND v_unit.status IN ('in_stock', 'reserved'))::integer;
        ELSE
            v_expected := app.sellable_on_hand(p_org, p_product_id, p_count.branch_id);
        END IF;
        INSERT INTO public.stock_count_lines (organization_id, count_id, product_id, unit_id, expected_qty,
                                              counted_qty, created_by, updated_by)
        VALUES (p_org, p_count.id, p_product_id, p_unit_id, v_expected, p_counted, p_emp, p_emp)
        RETURNING id INTO v_line;
    ELSE
        UPDATE public.stock_count_lines l
           SET counted_qty = CASE WHEN p_add THEN LEAST(COALESCE(l.counted_qty, 0) + p_counted,
                                                          CASE WHEN l.unit_id IS NULL THEN 1000000 ELSE 1 END)
                                  ELSE p_counted END,
               updated_by = p_emp
         WHERE l.id = v_line;
    END IF;
    RETURN v_line;
END;
$$;

-- Saves counted quantities (null = not counted yet). Draft data: not audited; the posted
-- adjustment is, with every changed line.
CREATE FUNCTION public.save_stock_count_lines(p_count_id uuid, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_count public.stock_counts; r record;
BEGIN
    v_emp := app.require_permission('stock.count');
    v_org := app.current_org_id();
    v_count := app.open_stock_count_for_write(v_org, p_count_id);
    IF v_count.status <> 'open' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the count is %', v_count.status USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM app.stock_lines_parse(p_lines, 'count') x
               GROUP BY x.product_id, x.unit_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    FOR r IN SELECT * FROM app.stock_lines_parse(p_lines, 'count') x ORDER BY x.product_id, x.unit_id NULLS FIRST LOOP
        PERFORM app.stock_count_set_line(v_org, v_emp, v_count, r.product_id, r.unit_id, r.qty, false);
    END LOOP;
    RETURN app.stock_count_json(v_org, p_count_id);
END;
$$;

-- A barcode gun on the count sheet: a serial counts that unit (1); a product barcode or SKU adds
-- one to that product's line. A serialized product's barcode is refused (scan its serial).
CREATE FUNCTION public.scan_stock_count(p_count_id uuid, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_count public.stock_counts; v_code text; v_unit public.units;
        v_product public.products; v_line uuid;
BEGIN
    v_emp := app.require_permission('stock.count');
    v_org := app.current_org_id();
    v_code := btrim(p_code);
    IF v_code IS NULL OR length(v_code) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: code' USING ERRCODE = 'P0001';
    END IF;
    v_count := app.open_stock_count_for_write(v_org, p_count_id);
    IF v_count.status <> 'open' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the count is %', v_count.status USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_unit FROM public.units u WHERE u.organization_id = v_org AND u.serial = v_code;
    IF FOUND THEN
        v_line := app.stock_count_set_line(v_org, v_emp, v_count, v_unit.product_id, v_unit.id, 1, false);
    ELSE
        SELECT * INTO v_product FROM public.products p
        WHERE p.organization_id = v_org AND p.archived_at IS NULL AND (p.barcode = v_code OR p.sku = upper(v_code))
        ORDER BY (p.barcode = v_code) DESC LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_product.is_serialized THEN
            RAISE EXCEPTION 'UNIT_REQUIRED: scan the serial of %', v_product.sku USING ERRCODE = 'P0001';
        END IF;
        v_line := app.stock_count_set_line(v_org, v_emp, v_count, v_product.id, NULL, 1, true);
    END IF;
    RETURN app.stock_count_line_json(v_org, p_count_id, v_line);
END;
$$;

-- Posts a count: stock becomes the counted numbers. Every difference goes into one adjustment
-- (reason 'count', numbered SA, the caller's idempotency key). A count already posted answers
-- its result again (a repeat changes nothing).
CREATE FUNCTION public.post_stock_count(p_count_id uuid, p_uncounted_as_zero boolean, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_count public.stock_counts; v_adj uuid; v_number text; v_lines jsonb;
    v_uncounted integer; v_key_count uuid; r record;
BEGIN
    v_emp := app.require_permission('stock.count');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT a.count_id INTO v_key_count FROM public.stock_adjustments a
    WHERE a.organization_id = v_org AND a.idempotency_key = p_idempotency_key;
    IF FOUND AND v_key_count IS DISTINCT FROM p_count_id THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE = 'P0001';
    END IF;

    v_count := app.open_stock_count_for_write(v_org, p_count_id);
    IF v_count.status = 'posted' THEN
        RETURN app.stock_count_json(v_org, p_count_id);
    END IF;
    IF v_count.status <> 'open' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the count is %', v_count.status USING ERRCODE = 'P0001';
    END IF;
    SELECT count(*) INTO v_uncounted FROM public.stock_count_lines l
    WHERE l.organization_id = v_org AND l.count_id = p_count_id AND l.counted_qty IS NULL;
    IF v_uncounted > 0 AND NOT COALESCE(p_uncounted_as_zero, false) THEN
        RAISE EXCEPTION 'STOCK_COUNT_INCOMPLETE: % lines not counted', v_uncounted USING ERRCODE = 'P0001';
    END IF;

    -- Lock what posting reads, product by product (units, then the level row), in the order the
    -- ledger triggers lock them, so a sale can't change the stock between reading and posting.
    FOR r IN SELECT DISTINCT l.product_id FROM public.stock_count_lines l
             WHERE l.organization_id = v_org AND l.count_id = p_count_id ORDER BY l.product_id LOOP
        PERFORM 1 FROM public.units u
        WHERE u.organization_id = v_org AND u.id IN (SELECT l.unit_id FROM public.stock_count_lines l
                                                     WHERE l.count_id = p_count_id AND l.product_id = r.product_id)
        ORDER BY u.id FOR UPDATE;
        PERFORM 1 FROM public.stock_levels sl
        WHERE sl.organization_id = v_org AND sl.product_id = r.product_id AND sl.branch_id = v_count.branch_id
          AND sl.stock_state = 'sellable'
        FOR UPDATE;
    END LOOP;

    -- Store the expected quantities as of now (locked), and the uncounted lines as zero if asked.
    UPDATE public.stock_count_lines l
       SET expected_qty = x.expected, counted_qty = COALESCE(l.counted_qty, 0), updated_by = v_emp
      FROM app.stock_count_lines_live(v_org, p_count_id) x
     WHERE l.id = x.line_id;

    SELECT jsonb_agg(jsonb_build_object('product_id', l.product_id, 'unit_id', l.unit_id,
                                        'quantity', l.counted_qty - l.expected_qty))
    INTO v_lines
    FROM public.stock_count_lines l
    WHERE l.organization_id = v_org AND l.count_id = p_count_id AND l.counted_qty <> l.expected_qty;

    IF v_lines IS NOT NULL THEN
        v_number := app.next_document_number(v_org, v_count.branch_id, 'stock_adjustment');
        INSERT INTO public.stock_adjustments (organization_id, number, branch_id, reason, count_id, idempotency_key, created_by)
        VALUES (v_org, v_number, v_count.branch_id, 'count', p_count_id, p_idempotency_key, v_emp)
        RETURNING id INTO v_adj;
        PERFORM app.post_adjustment_lines(v_org, v_emp, v_adj, v_count.branch_id, v_lines);
    END IF;

    UPDATE public.stock_counts c
       SET status = 'posted', posted_at = now(), posted_by = v_emp, updated_by = v_emp
     WHERE c.id = p_count_id;

    PERFORM app.write_audit('stock_count.posted', 'stock_count', p_count_id,
        jsonb_build_object('status', 'open'),
        jsonb_build_object('status', 'posted', 'number', v_count.number, 'adjustment_id', v_adj,
                           'adjustment_number', v_number, 'uncounted_as_zero', v_uncounted > 0,
                           'lines', COALESCE(v_lines, '[]'::jsonb)),
        NULL, v_count.branch_id);
    RETURN app.stock_count_json(v_org, p_count_id);
END;
$$;

CREATE FUNCTION public.cancel_stock_count(p_count_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_count public.stock_counts;
BEGIN
    v_emp := app.require_permission('stock.count');
    v_org := app.current_org_id();
    v_count := app.open_stock_count_for_write(v_org, p_count_id);
    IF v_count.status = 'cancelled' THEN
        RETURN app.stock_count_json(v_org, p_count_id);
    END IF;
    IF v_count.status <> 'open' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the count is %', v_count.status USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.stock_counts c SET status = 'cancelled', updated_by = v_emp WHERE c.id = p_count_id;
    PERFORM app.write_audit('stock_count.cancelled', 'stock_count', p_count_id,
        jsonb_build_object('status', 'open'), jsonb_build_object('status', 'cancelled', 'number', v_count.number),
        NULL, v_count.branch_id);
    RETURN app.stock_count_json(v_org, p_count_id);
END;
$$;

CREATE FUNCTION public.list_stock_counts(p_branch_id uuid DEFAULT NULL, p_status text DEFAULT NULL,
                                         p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.count') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.count' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_status IS NOT NULL AND p_status NOT IN ('open', 'posted', 'cancelled')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
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

    WITH found AS (
        SELECT c.id, c.created_at FROM public.stock_counts c
        WHERE c.organization_id = v_org AND c.branch_id = ANY(v_branches)
          AND (p_status IS NULL OR c.status::text = p_status)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.stock_count_json(v_org, f.id) ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- A count's lines, paged: 'all', 'uncounted' or 'different' (counted and not equal to expected);
-- search by name, SKU prefix, exact barcode or serial.
CREATE FUNCTION public.get_stock_count(p_id uuid, p_filter text DEFAULT 'all', p_search text DEFAULT NULL,
                                       p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid; v_search text; v_like text; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.count') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.count' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR COALESCE(p_filter, 'all') NOT IN ('all', 'uncounted', 'different') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := NULLIF(btrim(p_search), '');
    IF length(v_search) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: search' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');
    SELECT c.branch_id INTO v_branch FROM public.stock_counts c WHERE c.id = p_id AND c.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STOCK_COUNT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;

    WITH found AS (
        SELECT x.*, p.name_ar, p.name_en, p.sku, p.barcode, p.is_serialized, u.serial
        FROM app.stock_count_lines_live(v_org, p_id) x
        JOIN public.products p ON p.id = x.product_id AND p.organization_id = v_org
        LEFT JOIN public.units u ON u.id = x.unit_id AND u.organization_id = v_org
        WHERE (COALESCE(p_filter, 'all') = 'all'
               OR (p_filter = 'uncounted' AND x.counted IS NULL)
               OR (p_filter = 'different' AND x.counted IS NOT NULL AND x.counted <> x.expected))
          AND (v_search IS NULL
               OR p.name_ar ILIKE '%' || v_like || '%'
               OR p.name_en ILIKE '%' || v_like || '%'
               OR p.sku ILIKE v_like || '%'
               OR p.barcode = v_search
               OR u.serial = v_search)
    )
    SELECT app.stock_count_json(v_org, p_id) || jsonb_build_object(
        'lines', jsonb_build_object(
            'items', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id', f.line_id, 'product_id', f.product_id, 'name_ar', f.name_ar, 'name_en', f.name_en,
                    'sku', f.sku, 'barcode', f.barcode, 'is_serialized', f.is_serialized,
                    'unit_id', f.unit_id, 'serial', f.serial, 'expected_qty', f.expected,
                    'counted_qty', f.counted, 'difference', f.counted - f.expected)
                    ORDER BY f.name_ar, f.product_id, f.serial NULLS FIRST, f.line_id)
                FROM (SELECT * FROM found ORDER BY name_ar, product_id, serial NULLS FIRST, line_id
                      LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
            'total', (SELECT count(*) FROM found)))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 4. The movement drill-down (I01) shows the adjustment's number and reason ------------------------

CREATE OR REPLACE FUNCTION public.list_stock_movements(p_product_id uuid, p_branch_id uuid DEFAULT NULL,
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
                'source_number', a.number, 'reason', a.reason,
                'reverses_movement_id', x.reverses_movement_id, 'created_by_name', e.full_name)
                ORDER BY x.created_at DESC, x.id DESC)
            FROM (SELECT * FROM m ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) x
            LEFT JOIN public.units u ON u.id = x.unit_id AND u.organization_id = x.organization_id
            LEFT JOIN public.stock_adjustments a ON x.source_type = 'stock_adjustment'
                 AND a.id = x.source_id AND a.organization_id = x.organization_id
            LEFT JOIN public.employees e ON e.id = x.created_by AND e.organization_id = x.organization_id),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM m))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 5. Grants ---------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.sellable_on_hand(uuid, uuid, uuid), app.stock_lines_parse(jsonb, text),
    app.stock_adjustment_json(uuid, uuid, boolean), app.stock_count_lines_live(uuid, uuid),
    app.stock_count_json(uuid, uuid), app.stock_count_line_json(uuid, uuid, uuid),
    app.stock_count_scope(uuid, uuid), app.post_adjustment_lines(uuid, uuid, uuid, uuid, jsonb),
    app.open_stock_count_for_write(uuid, uuid),
    app.stock_count_set_line(uuid, uuid, public.stock_counts, uuid, uuid, integer, boolean)
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.post_stock_adjustment(uuid, text, text, jsonb, text),
    public.list_stock_adjustments(uuid, text, integer, integer), public.get_stock_adjustment(uuid),
    public.create_stock_count(uuid, uuid, text), public.save_stock_count_lines(uuid, jsonb),
    public.scan_stock_count(uuid, text), public.post_stock_count(uuid, boolean, text),
    public.cancel_stock_count(uuid), public.list_stock_counts(uuid, text, integer, integer),
    public.get_stock_count(uuid, text, text, integer, integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_stock_adjustment(uuid, text, text, jsonb, text),
    public.list_stock_adjustments(uuid, text, integer, integer), public.get_stock_adjustment(uuid),
    public.create_stock_count(uuid, uuid, text), public.save_stock_count_lines(uuid, jsonb),
    public.scan_stock_count(uuid, text), public.post_stock_count(uuid, boolean, text),
    public.cancel_stock_count(uuid), public.list_stock_counts(uuid, text, integer, integer),
    public.get_stock_count(uuid, text, text, integer, integer)
    TO authenticated;
