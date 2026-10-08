-- =============================================================================
-- I04 · Serial/IMEI units (EC-50, D50)
--
-- Every physical unit of a serialized product, one row in public.units (baseline): serial unique
-- per shop, product, branch, status, cost, purchase invoice line. Status and branch change only
-- through the ledger triggers (app.check_stock_movement / app.apply_stock_movement), which also
-- refuse selling or moving a unit that is not in stock in that branch.
--
-- register_units (user decision, 8 Oct): until purchases (U02) and the opening migration (M02)
--   exist, a shop registers serials it already holds: product, branch, cost, the serials (scanned
--   or typed). Needs stock.adjust, the branch and the 'serials' module. Serials are trimmed and
--   upper-cased; a serial used twice in the batch or already in the shop is refused
--   (SERIAL_TAKEN, the serials in the error detail). The batch is an import_jobs row
--   (kind opening_stock, completed); each unit gets an 'opening' movement (source 'import').
--   The caller's idempotency key is kept in the job's report (unique per shop). U02 and M02
--   reuse app.create_units.
-- get_unit / find_unit: the unit and its full history (every ledger row, oldest first) with
--   each document's number and party: sold to whom, bought from whom, transferred from where to
--   where, adjusted for what reason. stock.view; the unit's current branch must be accessible, and
--   steps in branches the caller can't access show no document, party or employee.
-- search_units: serial prefix search in the caller's branches (the "find a serial" box).
-- app.stock_source_json: a ledger row's document number and party; the I01 movement drill-down
--   now shows the number of every kind of document, not only adjustments.
-- Reads use app.has_permission (an expired shop can still read) and no module check (a shop that
-- leaves a serials plan still traces the units it has). Numbered after main (D39).
-- =============================================================================

CREATE UNIQUE INDEX import_jobs_idem_idx ON public.import_jobs (organization_id, (report ->> 'idempotency_key'))
    WHERE report ? 'idempotency_key';

-- 1. Documents ---------------------------------------------------------------------------------------

-- The number and the other party of a ledger row's source document (NULL when it has none).
CREATE FUNCTION app.stock_source_json(p_org uuid, p_type public.doc_type, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT CASE p_type
        WHEN 'sale' THEN (SELECT jsonb_build_object('number', s.number, 'party', c.full_name)
                          FROM public.sales s
                          LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
                          WHERE s.organization_id = p_org AND s.id = p_id)
        WHEN 'sales_return' THEN (SELECT jsonb_build_object('number', r.number, 'party', c.full_name)
                                  FROM public.sales_returns r
                                  JOIN public.sales s ON s.id = r.sale_id AND s.organization_id = r.organization_id
                                  LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
                                  WHERE r.organization_id = p_org AND r.id = p_id)
        WHEN 'delivery' THEN (SELECT jsonb_build_object('number', d.number, 'party', c.full_name)
                              FROM public.deliveries d
                              JOIN public.sales_orders o ON o.id = d.order_id AND o.organization_id = d.organization_id
                              LEFT JOIN public.customers c ON c.id = o.customer_id AND c.organization_id = o.organization_id
                              WHERE d.organization_id = p_org AND d.id = p_id)
        WHEN 'purchase_invoice' THEN (SELECT jsonb_build_object('number', i.number, 'party', sp.name)
                                      FROM public.purchase_invoices i
                                      JOIN public.suppliers sp ON sp.id = i.supplier_id AND sp.organization_id = i.organization_id
                                      WHERE i.organization_id = p_org AND i.id = p_id)
        WHEN 'purchase_return' THEN (SELECT jsonb_build_object('number', r.number, 'party', sp.name)
                                     FROM public.purchase_returns r
                                     JOIN public.suppliers sp ON sp.id = r.supplier_id AND sp.organization_id = r.organization_id
                                     WHERE r.organization_id = p_org AND r.id = p_id)
        WHEN 'transfer' THEN (SELECT jsonb_build_object('number', t.number, 'party', fb.name || ' → ' || tb.name)
                              FROM public.stock_transfers t
                              JOIN public.branches fb ON fb.id = t.from_branch_id AND fb.organization_id = t.organization_id
                              JOIN public.branches tb ON tb.id = t.to_branch_id AND tb.organization_id = t.organization_id
                              WHERE t.organization_id = p_org AND t.id = p_id)
        WHEN 'stock_adjustment' THEN (SELECT jsonb_build_object('number', a.number, 'party', NULL, 'reason', a.reason)
                                      FROM public.stock_adjustments a
                                      WHERE a.organization_id = p_org AND a.id = p_id)
        WHEN 'warranty_claim' THEN (SELECT jsonb_build_object('number', w.number, 'party', c.full_name)
                                    FROM public.warranty_claims w
                                    LEFT JOIN public.customers c ON c.id = w.customer_id AND c.organization_id = w.organization_id
                                    WHERE w.organization_id = p_org AND w.id = p_id)
        ELSE NULL END
$$;

-- 2. Creating units ----------------------------------------------------------------------------------

-- Serials of a write call: a JSON array of 1-500 strings, trimmed and upper-cased, each 1-64
-- characters of A-Z, 0-9 and . _ / - (starting with a letter or digit), none twice.
CREATE FUNCTION app.parse_serials(p_serials jsonb)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text[]; v_dup text[];
BEGIN
    IF jsonb_typeof(p_serials) IS DISTINCT FROM 'array' OR jsonb_array_length(p_serials) NOT BETWEEN 1 AND 500
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_serials) e WHERE jsonb_typeof(e) <> 'string') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: serials' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(upper(btrim(e)) ORDER BY o) INTO v FROM jsonb_array_elements_text(p_serials) WITH ORDINALITY x(e, o);
    IF EXISTS (SELECT 1 FROM unnest(v) s WHERE s !~ '^[A-Z0-9][A-Z0-9._/-]{0,63}$') THEN
        RAISE EXCEPTION 'SERIAL_INVALID' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(DISTINCT s ORDER BY s) INTO v_dup FROM unnest(v) s GROUP BY s HAVING count(*) > 1;
    IF v_dup IS NOT NULL THEN
        RAISE EXCEPTION 'SERIAL_TAKEN: repeated in the list' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('serials', to_jsonb(v_dup))::text;
    END IF;
    RETURN v;
END;
$$;

-- Creates the units of a product in a branch and posts one movement per unit (+1, the given
-- type and source), in serial order. The serials must be new in the shop (SERIAL_TAKEN lists the
-- ones that aren't). U02 calls it with 'purchase_in' and the invoice line; M02 with 'opening'.
CREATE FUNCTION app.create_units(p_org uuid, p_emp uuid, p_product_id uuid, p_branch_id uuid, p_serials text[],
                                 p_cost numeric, p_type public.stock_movement_type, p_source_type public.doc_type,
                                 p_source_id uuid, p_invoice_line_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_taken text[]; v_units jsonb;
BEGIN
    -- Two batches with the same serial queue here, so the second one sees the first one's rows.
    PERFORM pg_advisory_xact_lock(hashtextextended('serial/' || p_org::text || '/' || s, 0))
    FROM unnest(p_serials) s ORDER BY s;
    SELECT array_agg(u.serial ORDER BY u.serial) INTO v_taken
    FROM public.units u WHERE u.organization_id = p_org AND u.serial = ANY(p_serials);
    IF v_taken IS NOT NULL THEN
        RAISE EXCEPTION 'SERIAL_TAKEN: % already in the shop', array_length(v_taken, 1) USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('serials', to_jsonb(v_taken))::text;
    END IF;

    WITH made AS (
        INSERT INTO public.units (organization_id, product_id, serial, branch_id, cost, purchase_invoice_line_id, created_by, updated_by)
        SELECT p_org, p_product_id, s, p_branch_id, p_cost, p_invoice_line_id, p_emp, p_emp
        FROM unnest(p_serials) s ORDER BY s
        RETURNING id, serial
    )
    SELECT jsonb_agg(jsonb_build_object('id', m.id, 'serial', m.serial) ORDER BY m.serial) INTO v_units FROM made m;

    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type, stock_state,
                                        unit_cost, source_type, source_id, source_line_id, created_by)
    SELECT p_org, p_product_id, p_branch_id, (u ->> 'id')::uuid, 1, p_type, 'sellable', p_cost, p_source_type,
           p_source_id, p_invoice_line_id, p_emp
    FROM jsonb_array_elements(v_units) u
    ORDER BY (u ->> 'id')::uuid;
    RETURN v_units;
END;
$$;

CREATE FUNCTION public.register_units(p_product_id uuid, p_branch_id uuid, p_cost text, p_serials jsonb,
                                      p_note text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_job public.import_jobs; v_product public.products; v_serials text[];
    v_cost numeric(18,2); v_note text; v_units jsonb;
BEGIN
    v_emp := app.require_permission('stock.adjust');
    PERFORM app.require_module('serials');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_job FROM public.import_jobs j
    WHERE j.organization_id = v_org AND j.report ->> 'idempotency_key' = p_idempotency_key;
    IF FOUND THEN
        RETURN v_job.report - 'idempotency_key' || jsonb_build_object('import_job_id', v_job.id);   -- a repeat changes nothing
    END IF;

    SELECT * INTO v_product FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org;
    IF NOT FOUND OR v_product.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_product.is_serialized THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED: the product is not serialized' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF p_cost IS NULL OR p_cost !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: cost' USING ERRCODE = 'P0001';
    END IF;
    v_cost := p_cost::numeric(18,2);
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    v_serials := app.parse_serials(p_serials);

    INSERT INTO public.import_jobs (organization_id, kind, status, dry_run, rows_total, rows_ok, report, created_by, finished_at)
    VALUES (v_org, 'opening_stock', 'importing', false, array_length(v_serials, 1), 0, '{}'::jsonb, v_emp, NULL)
    RETURNING * INTO v_job;
    v_units := app.create_units(v_org, v_emp, p_product_id, p_branch_id, v_serials, v_cost, 'opening', 'import',
                                v_job.id, NULL);
    UPDATE public.import_jobs j
       SET status = 'completed', rows_ok = array_length(v_serials, 1), finished_at = now(),
           report = jsonb_build_object('kind', 'register_units', 'product_id', p_product_id, 'branch_id', p_branch_id,
                                       'cost', v_cost::text, 'note', v_note, 'count', array_length(v_serials, 1),
                                       'units', v_units, 'idempotency_key', p_idempotency_key)
     WHERE j.id = v_job.id
    RETURNING * INTO v_job;

    PERFORM app.write_audit('units.registered', 'import_job', v_job.id, NULL,
        jsonb_build_object('product_id', p_product_id, 'cost', v_cost::text, 'serials', to_jsonb(v_serials)),
        v_note, p_branch_id);
    RETURN v_job.report - 'idempotency_key' || jsonb_build_object('import_job_id', v_job.id);
END;
$$;

-- 3. Reads -------------------------------------------------------------------------------------------

-- A unit and its full history (oldest first): every ledger row with its document and party.
CREATE FUNCTION app.unit_json(p_org uuid, p_unit_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', u.id, 'serial', u.serial, 'product_id', u.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
        'sku', p.sku, 'branch_id', u.branch_id, 'branch_name', b.name, 'status', u.status,
        'cost', to_char(u.cost, 'FM9999999999999990.00'), 'created_at', u.created_at,
        'purchase_invoice_id', il.invoice_id, 'purchase_invoice_number', pi.number, 'supplier_name', sp.name,
        'history', COALESCE((
            -- Steps in a branch the caller can't access keep their date, type and branch only: no
            -- document number, party (a customer of another branch) or employee (security review).
            SELECT jsonb_agg(jsonb_build_object(
                'id', m.id, 'created_at', m.created_at, 'business_date', m.business_date, 'type', m.type,
                'quantity', m.quantity, 'branch_id', m.branch_id, 'branch_name', mb.name,
                'source_type', m.source_type, 'source_id', m.source_id,
                'source_number', CASE WHEN ok THEN src ->> 'number' END,
                'party_name', CASE WHEN ok THEN src ->> 'party' END,
                'reason', src ->> 'reason',
                'created_by_name', CASE WHEN ok THEN e.full_name END)
                ORDER BY m.created_at, m.id)
            FROM public.stock_movements m
            JOIN public.branches mb ON mb.id = m.branch_id AND mb.organization_id = m.organization_id
            LEFT JOIN public.employees e ON e.id = m.created_by AND e.organization_id = m.organization_id
            CROSS JOIN LATERAL (SELECT app.stock_source_json(p_org, m.source_type, m.source_id) AS src,
                                       app.has_branch_access(m.branch_id) AS ok) s
            WHERE m.organization_id = p_org AND m.unit_id = u.id), '[]'::jsonb))
    FROM public.units u
    JOIN public.products p ON p.id = u.product_id AND p.organization_id = u.organization_id
    JOIN public.branches b ON b.id = u.branch_id AND b.organization_id = u.organization_id
    LEFT JOIN public.purchase_invoice_lines il ON il.id = u.purchase_invoice_line_id AND il.organization_id = u.organization_id
    LEFT JOIN public.purchase_invoices pi ON pi.id = il.invoice_id AND pi.organization_id = il.organization_id
    LEFT JOIN public.suppliers sp ON sp.id = pi.supplier_id AND sp.organization_id = pi.organization_id
    WHERE u.organization_id = p_org AND u.id = p_unit_id
$$;

-- stock.view and the unit's current branch (OWNER: all); another shop's unit is not found.
CREATE FUNCTION app.unit_for_read(p_org uuid, p_unit_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_branch uuid;
BEGIN
    SELECT u.branch_id INTO v_branch FROM public.units u WHERE u.id = p_unit_id AND u.organization_id = p_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;
    RETURN app.unit_json(p_org, p_unit_id);
END;
$$;

CREATE FUNCTION public.get_unit(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    RETURN app.unit_for_read(app.current_org_id(), p_id);
END;
$$;

-- The exact serial (trimmed, upper-cased), as scanned.
CREATE FUNCTION public.find_unit(p_serial text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_id uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    IF p_serial IS NULL OR length(btrim(p_serial)) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: serial' USING ERRCODE = 'P0001';
    END IF;
    v_org := app.current_org_id();
    SELECT u.id INTO v_id FROM public.units u WHERE u.organization_id = v_org AND u.serial = upper(btrim(p_serial));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.unit_for_read(v_org, v_id);
END;
$$;

-- Units whose serial starts with p_search (or every unit), in the caller's branches; optional
-- status and branch. Ordered by serial.
CREATE FUNCTION public.search_units(p_search text DEFAULT NULL, p_status text DEFAULT NULL,
                                    p_branch_id uuid DEFAULT NULL, p_limit integer DEFAULT 50,
                                    p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_search text; v_like text; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_status IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM pg_catalog.pg_enum e WHERE e.enumtypid = 'public.unit_status'::regtype AND e.enumlabel = p_status)) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    v_search := upper(NULLIF(btrim(p_search), ''));
    IF length(v_search) > 64 THEN
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

    WITH found AS (
        SELECT u.id, u.serial, u.product_id, p.name_ar, p.name_en, p.sku, u.branch_id, b.name AS branch_name, u.status
        FROM public.units u
        JOIN public.products p ON p.id = u.product_id AND p.organization_id = u.organization_id
        JOIN public.branches b ON b.id = u.branch_id AND b.organization_id = u.organization_id
        WHERE u.organization_id = v_org AND u.branch_id = ANY(v_branches)
          AND (v_search IS NULL OR u.serial LIKE v_like || '%')
          AND (p_status IS NULL OR u.status::text = p_status)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(to_jsonb(f) ORDER BY f.serial)
            FROM (SELECT * FROM found ORDER BY serial LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 4. The I01 drill-down names every document ----------------------------------------------------------

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
                'source_number', src ->> 'number', 'reason', src ->> 'reason',
                'reverses_movement_id', x.reverses_movement_id, 'created_by_name', e.full_name)
                ORDER BY x.created_at DESC, x.id DESC)
            FROM (SELECT * FROM m ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) x
            LEFT JOIN public.units u ON u.id = x.unit_id AND u.organization_id = x.organization_id
            CROSS JOIN LATERAL (SELECT app.stock_source_json(v_org, x.source_type, x.source_id) AS src) s
            LEFT JOIN public.employees e ON e.id = x.created_by AND e.organization_id = x.organization_id),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM m))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- 5. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.stock_source_json(uuid, public.doc_type, uuid), app.parse_serials(jsonb),
    app.create_units(uuid, uuid, uuid, uuid, text[], numeric, public.stock_movement_type, public.doc_type, uuid, uuid),
    app.unit_json(uuid, uuid), app.unit_for_read(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.register_units(uuid, uuid, text, jsonb, text, text), public.get_unit(uuid),
    public.find_unit(text), public.search_units(text, text, uuid, integer, integer)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_units(uuid, uuid, text, jsonb, text, text), public.get_unit(uuid),
    public.find_unit(text), public.search_units(text, text, uuid, integer, integer)
    TO authenticated;
