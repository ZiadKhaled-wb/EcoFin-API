-- =============================================================================
-- S01 · Sale core (EC-68, D62)
--
-- The one transaction that turns a cart into a completed cash sale. The cashier's open shift
-- gives the branch and the drawer. In order: the idempotency key is locked (a repeat answers the
-- first sale), the shift, the cart's units and its stock rows are locked in a fixed order, the
-- cart is checked and priced by the server (list price, or another price with price.override),
-- the total is compared with what the cashier saw (PRICE_CHANGED), availability is checked
-- (OUT_OF_STOCK), and only then the number is taken and the sale, its lines with the tax
-- snapshot, the stock ledger rows (an IMEI unit becomes sold), the payment into the drawer and
-- the audit row are written. Anything refused leaves nothing behind.
--
-- public.post_sale is thin; app.post_sale_core does the work so installment sales (N02) and
-- orders (S10) can reuse it with their own payment step. Discounts are S03, other payment
-- methods S02, ETA receipts T02. No new tables, columns or enums.
-- =============================================================================

-- 1. The cart ------------------------------------------------------------------------------------------

-- The request's lines, checked for shape only: [{product_id, quantity, unit_id?, unit_price?}].
-- 1-100 lines; a unit line has quantity 1; a unit appears once; a product appears on one line
-- unless every one of its lines names a unit.
CREATE FUNCTION app.sale_lines_input(p_lines jsonb)
RETURNS TABLE (line_no integer, product_id uuid, quantity integer, unit_id uuid, unit_price numeric)
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_line jsonb; v_qty numeric; v_price text; i integer;
BEGIN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..jsonb_array_length(p_lines) LOOP
        v_line := p_lines -> (i - 1);
        IF jsonb_typeof(v_line) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_line) k
                      WHERE k NOT IN ('product_id', 'quantity', 'unit_id', 'unit_price'))
           OR jsonb_typeof(v_line -> 'product_id') IS DISTINCT FROM 'string'
           OR jsonb_typeof(v_line -> 'quantity') IS DISTINCT FROM 'number'
           OR COALESCE(jsonb_typeof(v_line -> 'unit_id'), 'null') NOT IN ('string', 'null')
           OR COALESCE(jsonb_typeof(v_line -> 'unit_price'), 'null') NOT IN ('string', 'number', 'null') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line %', i USING ERRCODE = 'P0001';
        END IF;
        v_qty := (v_line ->> 'quantity')::numeric;
        v_price := v_line ->> 'unit_price';
        IF v_qty <> trunc(v_qty) OR v_qty NOT BETWEEN 1 AND 100000
           OR (v_price IS NOT NULL AND v_price !~ '^\d{1,16}(\.\d{1,2})?$')
           OR (v_line ->> 'unit_id' IS NOT NULL AND v_qty <> 1) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: line %', i USING ERRCODE = 'P0001';
        END IF;
        line_no := i;
        product_id := (v_line ->> 'product_id')::uuid;
        quantity := v_qty::integer;
        unit_id := (v_line ->> 'unit_id')::uuid;
        unit_price := v_price::numeric;
        RETURN NEXT;
    END LOOP;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
END;
$$;

-- The cart as the server sees it: every line checked against the catalogue and the branch,
-- priced (list price unless the caller may override), and taxed by the T01 engine with the
-- shop's prices_include_vat. Reads only: the caller locks first when it is going to post.
-- Each line also carries what only the posting step needs (tax_class_id, unit_cost,
-- warranty_months); the quote removes those before answering.
CREATE FUNCTION app.sale_cart(p_org uuid, p_branch uuid, p_lines jsonb, p_can_override boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    r record; v_p public.products; v_u public.units; v_rate numeric; v_price numeric;
    v_inc boolean; v_available integer; v_tax jsonb; v_lines jsonb := '[]'; v_tax_lines jsonb := '[]';
    v_out jsonb := '[]'; i integer;
BEGIN
    IF EXISTS (SELECT 1 FROM app.sale_lines_input(p_lines) l WHERE l.unit_id IS NOT NULL
               GROUP BY l.unit_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM app.sale_lines_input(p_lines) l
                  GROUP BY l.product_id HAVING count(*) > 1 AND bool_or(l.unit_id IS NULL)) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a product or a unit appears twice' USING ERRCODE = 'P0001';
    END IF;
    SELECT s.prices_include_vat INTO v_inc FROM public.org_settings s WHERE s.organization_id = p_org;

    FOR r IN SELECT * FROM app.sale_lines_input(p_lines) ORDER BY line_no LOOP
        SELECT * INTO v_p FROM public.products p WHERE p.id = r.product_id AND p.organization_id = p_org;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_p.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'PRODUCT_ARCHIVED: %', v_p.sku USING ERRCODE = 'P0001';
        END IF;

        v_u := NULL;
        IF v_p.is_serialized THEN
            IF r.unit_id IS NULL THEN
                RAISE EXCEPTION 'UNIT_REQUIRED: product % is serialized', v_p.sku USING ERRCODE = 'P0001';
            END IF;
            SELECT * INTO v_u FROM public.units u WHERE u.id = r.unit_id AND u.organization_id = p_org;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_u.product_id <> v_p.id THEN
                RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
            END IF;
            -- A reserved unit waits for its order (S10): a walk-in sale doesn't take it.
            IF v_u.branch_id <> p_branch OR v_u.status <> 'in_stock' THEN
                RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: % is not in stock in this branch', v_u.serial
                    USING ERRCODE = 'P0001';
            END IF;
        ELSIF r.unit_id IS NOT NULL THEN
            RAISE EXCEPTION 'UNIT_NOT_ALLOWED: product % is not serialized', v_p.sku USING ERRCODE = 'P0001';
        END IF;

        v_price := v_p.cash_price;
        IF r.unit_price IS NOT NULL AND r.unit_price <> v_p.cash_price THEN
            IF NOT COALESCE(p_can_override, false) THEN
                RAISE EXCEPTION 'PRICE_OVERRIDE_DENIED: %', v_p.sku USING ERRCODE = '42501';
            END IF;
            v_price := r.unit_price;
        END IF;

        SELECT t.rate INTO v_rate FROM public.tax_classes t
        WHERE t.id = v_p.tax_class_id AND t.organization_id = p_org;
        SELECT COALESCE(sum(sl.on_hand - sl.reserved), 0)::integer INTO v_available
        FROM public.stock_levels sl
        WHERE sl.organization_id = p_org AND sl.product_id = v_p.id AND sl.branch_id = p_branch
          AND sl.stock_state = 'sellable';

        v_tax_lines := v_tax_lines || jsonb_build_object('unit_price', v_price::numeric(18,2)::text,
            'quantity', r.quantity, 'line_discount', '0', 'tax_rate', v_rate::numeric(5,2)::text);
        v_lines := v_lines || jsonb_build_object(
            'product_id', v_p.id, 'name_ar', v_p.name_ar, 'name_en', v_p.name_en, 'sku', v_p.sku,
            'is_serialized', v_p.is_serialized, 'unit_id', v_u.id, 'serial', v_u.serial,
            'quantity', r.quantity, 'list_price', v_p.cash_price::numeric(18,2)::text,
            'unit_price', v_price::numeric(18,2)::text, 'overridden', v_price <> v_p.cash_price,
            'tax_rate', v_rate::numeric(5,2)::text, 'available', v_available,
            'tax_class_id', v_p.tax_class_id, 'warranty_months', v_p.warranty_months,
            'unit_cost', CASE WHEN v_u.id IS NOT NULL THEN v_u.cost ELSE v_p.avg_cost END::numeric(18,4)::text);
    END LOOP;

    v_tax := app.compute_document_tax(jsonb_build_object(
        'prices_include_vat', v_inc, 'document_discount', '0', 'lines', v_tax_lines));
    FOR i IN 0..jsonb_array_length(v_lines) - 1 LOOP
        v_out := v_out || ((v_lines -> i) || jsonb_build_object(
            'tax_amount', v_tax -> 'lines' -> i ->> 'tax', 'line_total', v_tax -> 'lines' -> i ->> 'gross'));
    END LOOP;
    RETURN jsonb_build_object('prices_include_vat', v_inc, 'lines', v_out,
        'subtotal', v_tax ->> 'subtotal', 'tax_total', v_tax ->> 'tax_total', 'total', v_tax ->> 'total');
END;
$$;

-- The shop's customer, or CUSTOMER_NOT_FOUND (NULL = a walk-in sale).
CREATE FUNCTION app.sale_customer(p_org uuid, p_customer_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.customers c
        WHERE c.id = p_customer_id AND c.organization_id = p_org AND c.archived_at IS NULL) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
END;
$$;

-- 2. Reading a sale ------------------------------------------------------------------------------------

CREATE FUNCTION app.sale_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'shift_id', s.shift_id,
        'shift_number', sh.number, 'customer_id', s.customer_id, 'customer_name', c.full_name,
        'prices_include_vat', s.prices_include_vat, 'subtotal', s.subtotal::text,
        'discount_total', s.discount_total::text, 'tax_total', s.tax_total::text, 'total', s.total::text,
        'business_date', s.business_date, 'issued_at', s.issued_at, 'created_by_name', e.full_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'line_no', l.line_no, 'product_id', l.product_id, 'name_ar', p.name_ar,
                'name_en', p.name_en, 'sku', p.sku, 'is_serialized', p.is_serialized,
                'unit_id', l.unit_id, 'serial', u.serial, 'quantity', l.quantity,
                'unit_price', l.unit_price::text, 'tax_rate', l.tax_rate::numeric(5,2)::text,
                'tax_amount', l.tax_amount::text, 'line_total', l.line_total::text,
                'warranty_until', l.warranty_until) ORDER BY l.line_no)
            FROM public.sale_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.sale_id = s.id), '[]'::jsonb),
        'payments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', pay.id, 'number', pay.number, 'method', pay.method, 'amount', a.amount::text,
                'cash_account_id', pay.cash_account_id, 'cash_account_name', ca.name,
                'reference', pay.reference) ORDER BY pay.number)
            FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            LEFT JOIN public.cash_accounts ca ON ca.id = pay.cash_account_id
                                             AND ca.organization_id = pay.organization_id
            WHERE a.organization_id = p_org AND a.sale_id = s.id), '[]'::jsonb))
    FROM public.sales s
    LEFT JOIN public.shifts sh ON sh.id = s.shift_id AND sh.organization_id = s.organization_id
    LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
    LEFT JOIN public.employees e ON e.id = s.created_by AND e.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;

-- 3. Posting -------------------------------------------------------------------------------------------

-- S01's payment step: the whole total in cash into the shift's drawer. One payment (PY), its
-- allocation to the sale and one cash ledger row tagged with the shift. S02 replaces this with
-- payment lines; N02 will pay a down payment here.
CREATE FUNCTION app.post_sale_payments(p_sale public.sales, p_shift public.shifts, p_emp uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_payment uuid;
BEGIN
    INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id,
                                 cash_account_id, shift_id, received_by, business_date, idempotency_key,
                                 created_by)
    VALUES (p_sale.organization_id,
            app.next_document_number(p_sale.organization_id, p_sale.branch_id, 'payment'), p_sale.branch_id,
            'in', 'cash', p_sale.total, p_sale.customer_id, p_shift.drawer_account_id, p_shift.id, p_emp,
            p_sale.business_date, 'system:sale:' || p_sale.id::text || ':1', p_emp)
    RETURNING id INTO v_payment;
    INSERT INTO public.payment_allocations (organization_id, payment_id, amount, sale_id, created_by)
    VALUES (p_sale.organization_id, v_payment, p_sale.total, p_sale.id, p_emp);
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                       source_type, source_id, note, business_date, created_by, created_at)
    VALUES (p_sale.organization_id, p_shift.drawer_account_id, p_sale.branch_id, p_shift.id, p_sale.total,
            'sale', 'sale', p_sale.id, p_sale.number, p_sale.business_date, p_emp, clock_timestamp());
END;
$$;

-- The sale itself, for a caller that has already checked the permission, locked the
-- idempotency key and holds the (locked, open) shift. Returns the new sale's id.
CREATE FUNCTION app.post_sale_core(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                   p_customer_id uuid, p_expected_total numeric, p_idempotency_key text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_cart jsonb; v_line jsonb; v_total numeric(18,2); v_date date; v_sale public.sales; v_line_id uuid;
    v_cost numeric := 0; v_overrides jsonb; i integer;
BEGIN
    PERFORM app.sale_customer(p_org, p_customer_id);

    -- Locks, always in the same order so two tills can't deadlock: the cart's units by id, then
    -- its stock rows by product id. (app.sale_lines_input has already refused a malformed cart.)
    PERFORM 1 FROM public.units u
    WHERE u.organization_id = p_org
      AND u.id IN (SELECT l.unit_id FROM app.sale_lines_input(p_lines) l WHERE l.unit_id IS NOT NULL)
    ORDER BY u.id FOR UPDATE;
    PERFORM 1 FROM public.stock_levels sl
    WHERE sl.organization_id = p_org AND sl.branch_id = p_shift.branch_id AND sl.stock_state = 'sellable'
      AND sl.product_id IN (SELECT l.product_id FROM app.sale_lines_input(p_lines) l)
    ORDER BY sl.product_id FOR UPDATE;

    -- Priced and checked on what is committed now (a new statement after the locks).
    v_cart := app.sale_cart(p_org, p_shift.branch_id, p_lines, app.has_permission('price.override'));
    v_total := (v_cart ->> 'total')::numeric;
    IF v_total <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a sale must total more than 0' USING ERRCODE = 'P0001';
    END IF;
    IF p_expected_total IS NULL OR p_expected_total <> v_total THEN
        RAISE EXCEPTION 'PRICE_CHANGED: expected %, the total is %', p_expected_total, v_total
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('expected_total', p_expected_total::numeric(18,2)::text,
                                              'total', v_total::text)::text;
    END IF;
    -- Availability per product (a serialized product may be on several lines), on locked rows.
    SELECT jsonb_build_object('product_id', k.product_id, 'requested', k.requested, 'available', k.available,
                              'sku', k.sku)
    INTO v_line
    FROM (SELECT l ->> 'product_id' AS product_id, min(l ->> 'sku') AS sku,
                 sum((l ->> 'quantity')::integer)::integer AS requested,
                 min((l ->> 'available')::integer) AS available
          FROM jsonb_array_elements(v_cart -> 'lines') l GROUP BY 1) k
    WHERE k.requested > k.available
    ORDER BY k.product_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OUT_OF_STOCK: % (asked %, available %)', v_line ->> 'sku',
                v_line ->> 'requested', v_line ->> 'available'
            USING ERRCODE = 'P0001', DETAIL = (v_line - 'sku')::text;
    END IF;
    SELECT sum((l ->> 'quantity')::integer * (l ->> 'unit_cost')::numeric) INTO v_cost
    FROM jsonb_array_elements(v_cart -> 'lines') l;

    -- Everything is checked: now the number, the document and the ledgers.
    v_date := app.org_today(p_org);
    INSERT INTO public.sales (organization_id, number, branch_id, device_id, shift_id, customer_id, kind,
                              is_b2b, prices_include_vat, subtotal, discount_total, tax_total, total,
                              cost_total, issued_at, business_date, idempotency_key, created_by)
    VALUES (p_org, app.next_document_number(p_org, p_shift.branch_id, 'sale'), p_shift.branch_id,
            p_shift.device_id, p_shift.id, p_customer_id, 'pos', false,
            (v_cart ->> 'prices_include_vat')::boolean, (v_cart ->> 'subtotal')::numeric, 0,
            (v_cart ->> 'tax_total')::numeric, v_total, round(v_cost, 2), clock_timestamp(), v_date,
            p_idempotency_key, p_emp)
    RETURNING * INTO v_sale;

    FOR i IN 0..jsonb_array_length(v_cart -> 'lines') - 1 LOOP
        v_line := v_cart -> 'lines' -> i;
        INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, unit_id, quantity,
                                       unit_price, discount_amount, tax_class_id, tax_rate, tax_amount,
                                       line_total, unit_cost, warranty_until, created_by)
        VALUES (p_org, v_sale.id, i + 1, (v_line ->> 'product_id')::uuid, (v_line ->> 'unit_id')::uuid,
                (v_line ->> 'quantity')::integer, (v_line ->> 'unit_price')::numeric, 0,
                (v_line ->> 'tax_class_id')::uuid, (v_line ->> 'tax_rate')::numeric,
                (v_line ->> 'tax_amount')::numeric, (v_line ->> 'line_total')::numeric,
                (v_line ->> 'unit_cost')::numeric,
                CASE WHEN (v_line ->> 'warranty_months')::integer > 0
                     THEN (v_date + make_interval(months => (v_line ->> 'warranty_months')::integer))::date END,
                p_emp)
        RETURNING id INTO v_line_id;
        -- The stock ledger: the trigger lowers the level (never below what is reserved) and
        -- marks a unit sold; it refuses again if anything slipped past the checks above.
        INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                            unit_cost, source_type, source_id, source_line_id, business_date,
                                            created_by, created_at)
        VALUES (p_org, (v_line ->> 'product_id')::uuid, p_shift.branch_id, (v_line ->> 'unit_id')::uuid,
                -(v_line ->> 'quantity')::integer, 'sale_out', (v_line ->> 'unit_cost')::numeric, 'sale',
                v_sale.id, v_line_id, v_date, p_emp, clock_timestamp());
    END LOOP;

    PERFORM app.post_sale_payments(v_sale, p_shift, p_emp);

    SELECT jsonb_agg(jsonb_build_object('product_id', l ->> 'product_id', 'sku', l ->> 'sku',
                                        'list_price', l ->> 'list_price', 'unit_price', l ->> 'unit_price'))
    INTO v_overrides
    FROM jsonb_array_elements(v_cart -> 'lines') l WHERE (l ->> 'overridden')::boolean;
    PERFORM app.write_audit('sale.created', 'sale', v_sale.id, NULL,
        jsonb_build_object('number', v_sale.number, 'total', v_sale.total::text,
                           'tax_total', v_sale.tax_total::text,
                           'lines', jsonb_array_length(v_cart -> 'lines'), 'customer_id', p_customer_id,
                           'shift_id', p_shift.id, 'price_overrides', COALESCE(v_overrides, '[]'::jsonb)),
        NULL, v_sale.branch_id,
        CASE WHEN v_overrides IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN v_sale.id;
END;
$$;

-- 4. The public functions ------------------------------------------------------------------------------

-- A cash sale by the caller, in their open shift. p_expected_total is the total the cashier saw.
CREATE FUNCTION public.post_sale(p_lines jsonb, p_expected_total text, p_idempotency_key text,
                                 p_customer_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_existing uuid; v_shift public.shifts; v_expected numeric;
BEGIN
    v_emp := app.require_permission('sale.create');
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT s.id INTO v_existing FROM public.sales s
    WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.sale_json(v_org, v_existing);             -- a repeat sells nothing
    END IF;

    IF p_expected_total IS NULL OR p_expected_total !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: expected_total' USING ERRCODE = 'P0001';
    END IF;
    v_expected := p_expected_total::numeric;
    PERFORM app.sale_lines_input(p_lines);                   -- a malformed cart stops here

    -- The caller's open shift, locked: it can't be closed while this sale is being written.
    v_shift := app.require_open_shift(v_org, v_emp);
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);

    -- Two statements on purpose: the read below must start after the sale is written (a STABLE
    -- function called in the same statement as the write would not see it).
    v_existing := app.post_sale_core(v_org, v_emp, v_shift, p_lines, p_customer_id, v_expected,
                                     p_idempotency_key);
    RETURN app.sale_json(v_org, v_existing);
END;
$$;

-- Prices a cart without selling it: the same checks and the same tax engine, nothing locked and
-- nothing written. `available` is reported per line, not enforced. A read: works in an expired shop.
CREATE FUNCTION public.quote_sale(p_lines jsonb, p_customer_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id(); v_org uuid; v_shift public.shifts; v_cart jsonb;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('sale.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    v_shift := app.require_open_shift(v_org, v_emp);
    PERFORM app.sale_customer(v_org, p_customer_id);
    v_cart := app.sale_cart(v_org, v_shift.branch_id, p_lines, app.has_permission('price.override'));
    RETURN jsonb_set(v_cart, '{lines}', (
        SELECT jsonb_agg(l - 'tax_class_id' - 'unit_cost' - 'warranty_months' ORDER BY o)
        FROM jsonb_array_elements(v_cart -> 'lines') WITH ORDINALITY x(l, o)));
END;
$$;

-- The caller's own sale (sale.create), or any sale of the caller's branches with report.view or
-- cash.view. Everything else, another shop's included: SALE_NOT_FOUND.
CREATE FUNCTION public.get_sale(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id(); v_org uuid; v_s public.sales;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('sale.create') OR app.has_permission('report.view')
            OR app.has_permission('cash.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT * INTO v_s FROM public.sales s WHERE s.id = p_id AND s.organization_id = v_org;
    IF NOT FOUND OR NOT (
        v_s.created_by = v_emp
        OR ((app.has_permission('report.view') OR app.has_permission('cash.view'))
            AND app.has_branch_access(v_s.branch_id))) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.sale_json(v_org, p_id);
END;
$$;

-- 5. Grants --------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.sale_lines_input(jsonb), app.sale_cart(uuid, uuid, jsonb, boolean),
    app.sale_customer(uuid, uuid), app.sale_json(uuid, uuid),
    app.post_sale_payments(public.sales, public.shifts, uuid),
    app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_sale(jsonb, text, text, uuid), public.quote_sale(jsonb, uuid),
    public.get_sale(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_sale(jsonb, text, text, uuid), public.quote_sale(jsonb, uuid),
    public.get_sale(uuid)
    TO authenticated;
