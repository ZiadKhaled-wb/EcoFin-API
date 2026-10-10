-- =============================================================================
-- S02 · Split payments (EC-69, D64)
--
-- One sale can be paid with up to five payment lines: cash into the shift's drawer (optionally
-- with the amount the customer handed over, so the change can be shown), a bank transfer into a
-- bank account with its reference, and the customer's store credit. The lines must add up to the
-- sale total exactly. Each line is one payment (PY) with its allocation to the sale and posts to
-- its own ledger: the drawer (tagged with the shift), the bank (no shift: K02's trigger keeps
-- shift rows on the drawer) or the customer's store credit balance. Without `payments` the sale
-- is paid in cash in full, exactly as in S01.
--
-- The payment step takes the amount it must cover as a parameter (the sale total here; N02 will
-- pass a down payment). The shift reports what it took by method (K04 will sum the same rows).
-- The only schema change is payments.tendered.
-- =============================================================================

-- 1. The only schema change --------------------------------------------------------------------------

ALTER TABLE public.payments ADD COLUMN tendered numeric(18,2);
ALTER TABLE public.payments ADD CONSTRAINT payments_tendered_check
    CHECK (tendered IS NULL OR (method = 'cash' AND tendered >= amount));

-- The new signatures replace S01's: drop the old ones first.
DROP FUNCTION public.post_sale(jsonb, text, text, uuid);
DROP FUNCTION public.quote_sale(jsonb, uuid);
DROP FUNCTION app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text);
DROP FUNCTION app.post_sale_payments(public.sales, public.shifts, uuid);

-- 2. Payment lines -----------------------------------------------------------------------------------

-- The request's payment lines, checked for shape and limits only:
-- [{method, amount, tendered?}, {method: 'bank_transfer', amount, cash_account_id, reference},
--  {method: 'store_credit', amount}]. 1-5 lines; at most one cash, one store credit, three banks;
-- every amount above 0 with at most 2 decimals; tendered at least the amount.
CREATE FUNCTION app.sale_payments_input(p_payments jsonb)
RETURNS TABLE (line_no integer, method text, amount numeric, tendered numeric, cash_account_id uuid,
               reference text)
LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE
    v_l jsonb; i integer; v_allowed text[]; v_amt text; v_ten text; v_ref text;
    v_cash integer := 0; v_credit integer := 0; v_bank integer := 0;
BEGIN
    IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array'
       OR jsonb_array_length(p_payments) NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payments' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 1..jsonb_array_length(p_payments) LOOP
        v_l := p_payments -> (i - 1);
        IF jsonb_typeof(v_l) <> 'object' OR jsonb_typeof(v_l -> 'method') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: payment %', i USING ERRCODE = 'P0001';
        END IF;
        v_allowed := CASE v_l ->> 'method'
            WHEN 'cash' THEN ARRAY['method', 'amount', 'tendered']
            WHEN 'bank_transfer' THEN ARRAY['method', 'amount', 'cash_account_id', 'reference']
            WHEN 'store_credit' THEN ARRAY['method', 'amount'] END;
        IF v_allowed IS NULL
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_l) k WHERE k <> ALL (v_allowed))
           OR COALESCE(jsonb_typeof(v_l -> 'amount'), 'null') NOT IN ('string', 'number')
           OR COALESCE(jsonb_typeof(v_l -> 'tendered'), 'null') NOT IN ('string', 'number', 'null') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: payment %', i USING ERRCODE = 'P0001';
        END IF;
        v_amt := v_l ->> 'amount';
        v_ten := v_l ->> 'tendered';
        IF v_amt !~ '^\d{1,16}(\.\d{1,2})?$' OR v_amt::numeric <= 0
           OR (v_ten IS NOT NULL AND (v_ten !~ '^\d{1,16}(\.\d{1,2})?$' OR v_ten::numeric < v_amt::numeric)) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: payment %', i USING ERRCODE = 'P0001';
        END IF;
        v_ref := NULL;
        IF v_l ->> 'method' = 'bank_transfer' THEN
            IF jsonb_typeof(v_l -> 'cash_account_id') IS DISTINCT FROM 'string'
               OR jsonb_typeof(v_l -> 'reference') IS DISTINCT FROM 'string' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: payment %', i USING ERRCODE = 'P0001';
            END IF;
            v_ref := btrim(v_l ->> 'reference');
            IF length(v_ref) NOT BETWEEN 1 AND 100 THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: payment % reference', i USING ERRCODE = 'P0001';
            END IF;
            v_bank := v_bank + 1;
        ELSIF v_l ->> 'method' = 'cash' THEN
            v_cash := v_cash + 1;
        ELSE
            v_credit := v_credit + 1;
        END IF;
        IF v_cash > 1 OR v_credit > 1 OR v_bank > 3 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: too many payments of one method' USING ERRCODE = 'P0001';
        END IF;
        line_no := i;
        method := v_l ->> 'method';
        amount := v_amt::numeric;
        tendered := v_ten::numeric;
        cash_account_id := (v_l ->> 'cash_account_id')::uuid;
        reference := v_ref;
        RETURN NEXT;
    END LOOP;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payments' USING ERRCODE = 'P0001';
END;
$$;

-- The checks that need the shop's data and no locks (the quote runs them too): a bank transfer
-- goes into an active bank of the sale's branch or a shop-wide one, store credit needs the sale's
-- customer. Returns nothing; refuses with the contract code.
CREATE FUNCTION app.sale_payments_check(p_org uuid, p_branch uuid, p_customer uuid, p_payments jsonb)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_a public.cash_accounts;
BEGIN
    FOR r IN SELECT * FROM app.sale_payments_input(p_payments) ORDER BY line_no LOOP
        IF r.method = 'bank_transfer' THEN
            SELECT * INTO v_a FROM public.cash_accounts a WHERE a.id = r.cash_account_id AND a.organization_id = p_org;
            IF NOT FOUND OR v_a.kind <> 'bank'
               OR (v_a.branch_id IS NOT NULL AND v_a.branch_id <> p_branch) THEN
                RAISE EXCEPTION 'VAULT_INVALID' USING ERRCODE = 'P0001';
            END IF;
            IF NOT v_a.is_active THEN
                RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
            END IF;
        ELSIF r.method = 'store_credit' AND p_customer IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: store credit needs a customer' USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
END;
$$;

-- The payment step of a sale: one payment, its allocation and its ledger row per line, in the
-- order given. p_payments NULL = the whole amount in cash (S01's behaviour). p_amount is what the
-- lines must add up to. Returns the lines as posted, for the audit row.
CREATE FUNCTION app.post_sale_payments(p_sale public.sales, p_shift public.shifts, p_emp uuid,
                                       p_payments jsonb, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid := p_sale.organization_id; v_lines jsonb; v_paid numeric; r record; v_payment uuid;
    v_balance numeric; v_out jsonb := '[]'; v_account uuid;
BEGIN
    v_lines := COALESCE(p_payments, jsonb_build_array(
        jsonb_build_object('method', 'cash', 'amount', p_amount::numeric(18,2)::text)));
    SELECT COALESCE(sum(l.amount), 0) INTO v_paid FROM app.sale_payments_input(v_lines) l;
    IF v_paid <> p_amount THEN
        RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH: the payments add up to %, the sale to %', v_paid, p_amount
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('total', p_amount::numeric(18,2)::text,
                                              'paid', v_paid::numeric(18,2)::text)::text;
    END IF;
    PERFORM app.sale_payments_check(v_org, p_sale.branch_id, p_sale.customer_id, v_lines);

    FOR r IN SELECT * FROM app.sale_payments_input(v_lines) ORDER BY line_no LOOP
        v_account := CASE r.method WHEN 'cash' THEN p_shift.drawer_account_id
                                   WHEN 'bank_transfer' THEN r.cash_account_id END;
        IF r.method = 'bank_transfer' THEN
            PERFORM 1 FROM public.cash_accounts a WHERE a.id = r.cash_account_id AND a.organization_id = v_org
            FOR SHARE;
        ELSIF r.method = 'store_credit' THEN
            -- The balance is locked while it is read, so two sales can't spend it twice.
            SELECT b.balance INTO v_balance FROM public.store_credit_balances b
            WHERE b.customer_id = p_sale.customer_id FOR UPDATE;
            v_balance := COALESCE(v_balance, 0);
            IF v_balance < r.amount THEN
                RAISE EXCEPTION 'INSUFFICIENT_STORE_CREDIT: the balance is %', v_balance
                    USING ERRCODE = 'P0001',
                          DETAIL = jsonb_build_object('balance', v_balance::numeric(18,2)::text)::text;
            END IF;
        END IF;

        INSERT INTO public.payments (organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, reference, tendered, received_by, business_date,
                                     idempotency_key, created_by)
        VALUES (v_org, app.next_document_number(v_org, p_sale.branch_id, 'payment'), p_sale.branch_id, 'in',
                r.method::public.payment_method, r.amount, p_sale.customer_id, v_account, p_shift.id,
                r.reference, r.tendered, p_emp, p_sale.business_date,
                'system:sale:' || p_sale.id::text || ':' || r.line_no, p_emp)
        RETURNING id INTO v_payment;
        INSERT INTO public.payment_allocations (organization_id, payment_id, amount, sale_id, created_by)
        VALUES (v_org, v_payment, r.amount, p_sale.id, p_emp);

        IF r.method = 'cash' THEN
            INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                               source_type, source_id, note, business_date, created_by, created_at)
            VALUES (v_org, v_account, p_sale.branch_id, p_shift.id, r.amount, 'sale', 'sale', p_sale.id,
                    p_sale.number, p_sale.business_date, p_emp, clock_timestamp());
        ELSIF r.method = 'bank_transfer' THEN
            INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type,
                                               source_type, source_id, note, business_date, created_by, created_at)
            VALUES (v_org, v_account, p_sale.branch_id, r.amount, 'sale', 'sale', p_sale.id,
                    left(p_sale.number || ' ' || r.reference, 200), p_sale.business_date, p_emp, clock_timestamp());
        ELSE
            INSERT INTO public.store_credit_movements (organization_id, customer_id, amount, source_type, source_id,
                                                       branch_id, business_date, created_by, created_at)
            VALUES (v_org, p_sale.customer_id, -r.amount, 'sale', p_sale.id, p_sale.branch_id,
                    p_sale.business_date, p_emp, clock_timestamp());
        END IF;
        v_out := v_out || jsonb_build_object('method', r.method, 'amount', r.amount::numeric(18,2)::text,
                                             'cash_account_id', v_account, 'reference', r.reference);
    END LOOP;
    RETURN v_out;
END;
$$;

-- 3. Reading a sale and a shift ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.sale_json(p_org uuid, p_id uuid)
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
                'reference', pay.reference, 'tendered', pay.tendered::text,
                'change', (pay.tendered - a.amount)::numeric(18,2)::text) ORDER BY pay.number)
            FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            LEFT JOIN public.cash_accounts ca ON ca.id = pay.cash_account_id
                                             AND ca.organization_id = pay.organization_id
            WHERE a.organization_id = p_org AND a.sale_id = s.id), '[]'::jsonb),
        'paid_total', COALESCE((
            SELECT sum(a.amount) FROM public.payment_allocations a
            WHERE a.organization_id = p_org AND a.sale_id = s.id), 0)::numeric(18,2)::text,
        'change_total', COALESCE((
            SELECT sum(pay.tendered - a.amount) FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            WHERE a.organization_id = p_org AND a.sale_id = s.id), 0)::numeric(18,2)::text)
    FROM public.sales s
    LEFT JOIN public.shifts sh ON sh.id = s.shift_id AND sh.organization_id = s.organization_id
    LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
    LEFT JOIN public.employees e ON e.id = s.created_by AND e.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;

-- K02's shift, plus what it took: sales_total and the incoming payments of the shift by method.
CREATE OR REPLACE FUNCTION app.shift_json(p_org uuid, p_id uuid, p_with_movements boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'number', s.number, 'branch_id', s.branch_id, 'device_id', s.device_id,
        'device_name', d.name, 'employee_id', s.employee_id, 'employee_name', e.full_name,
        'drawer_account_id', s.drawer_account_id, 'status', s.status,
        'opening_float', s.opening_float::text, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
        'closed_by_name', ce.full_name,
        'expected_cash', CASE WHEN s.status = 'open' THEN app.shift_expected(p_org, s)
                              ELSE s.expected_cash END::numeric(18,2)::text,
        'counted_cash', s.counted_cash::text,
        'difference', (s.counted_cash - s.expected_cash)::numeric(18,2)::text,
        'count_breakdown', s.count_breakdown, 'difference_reason', s.difference_reason,
        'sales_total', COALESCE((SELECT sum(x.total) FROM public.sales x
                                 WHERE x.organization_id = p_org AND x.shift_id = s.id), 0)::numeric(18,2)::text,
        'payment_totals', (
            SELECT jsonb_build_object(
                'cash', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'cash'), 0)::numeric(18,2)::text,
                'bank_transfer', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'bank_transfer'), 0)::numeric(18,2)::text,
                'store_credit', COALESCE(sum(p.amount) FILTER (WHERE p.method = 'store_credit'), 0)::numeric(18,2)::text)
            FROM public.payments p
            WHERE p.organization_id = p_org AND p.shift_id = s.id AND p.direction = 'in'))
        || CASE WHEN p_with_movements THEN jsonb_build_object('movements', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', m.id, 'created_at', m.created_at, 'type', m.type, 'amount', m.amount::text,
                'source_type', m.source_type,
                'source_number', CASE m.source_type WHEN 'cash_transfer' THEN
                    (SELECT t.number FROM public.cash_transfers t
                     WHERE t.id = m.source_id AND t.organization_id = p_org) END,
                'note', m.note)
                ORDER BY m.created_at, m.id)
            FROM public.cash_movements m
            WHERE m.organization_id = p_org AND m.shift_id = s.id AND m.cash_account_id = s.drawer_account_id),
            '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.shifts s
    JOIN public.employees e ON e.id = s.employee_id AND e.organization_id = s.organization_id
    LEFT JOIN public.employees ce ON ce.id = s.closed_by AND ce.organization_id = s.organization_id
    LEFT JOIN public.devices d ON d.id = s.device_id AND d.organization_id = s.organization_id
    WHERE s.organization_id = p_org AND s.id = p_id
$$;

-- 4. Posting -----------------------------------------------------------------------------------------

-- S01's sale core with the payment lines. p_payments NULL = paid in cash in full.
CREATE FUNCTION app.post_sale_core(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                   p_customer_id uuid, p_expected_total numeric, p_idempotency_key text,
                                   p_payments jsonb DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_cart jsonb; v_line jsonb; v_total numeric(18,2); v_date date; v_sale public.sales; v_line_id uuid;
    v_cost numeric := 0; v_overrides jsonb; v_paid jsonb; i integer;
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

    v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, v_total);

    SELECT jsonb_agg(jsonb_build_object('product_id', l ->> 'product_id', 'sku', l ->> 'sku',
                                        'list_price', l ->> 'list_price', 'unit_price', l ->> 'unit_price'))
    INTO v_overrides
    FROM jsonb_array_elements(v_cart -> 'lines') l WHERE (l ->> 'overridden')::boolean;
    PERFORM app.write_audit('sale.created', 'sale', v_sale.id, NULL,
        jsonb_build_object('number', v_sale.number, 'total', v_sale.total::text,
                           'tax_total', v_sale.tax_total::text,
                           'lines', jsonb_array_length(v_cart -> 'lines'), 'customer_id', p_customer_id,
                           'shift_id', p_shift.id, 'price_overrides', COALESCE(v_overrides, '[]'::jsonb),
                           'payments', v_paid),
        NULL, v_sale.branch_id,
        CASE WHEN v_overrides IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN v_sale.id;
END;
$$;

-- 5. The public functions ----------------------------------------------------------------------------

-- A sale by the caller, in their open shift. p_expected_total is the total the cashier saw.
-- p_payments: the payment lines; NULL = paid in cash in full.
CREATE FUNCTION public.post_sale(p_lines jsonb, p_expected_total text, p_idempotency_key text,
                                 p_customer_id uuid DEFAULT NULL, p_payments jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_existing uuid; v_shift public.shifts; v_expected numeric;
    v_payments jsonb := CASE WHEN p_payments = 'null'::jsonb THEN NULL ELSE p_payments END;
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
    IF v_payments IS NOT NULL THEN
        PERFORM app.sale_payments_input(v_payments);         -- so does a malformed payment list
    END IF;

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
                                     p_idempotency_key, v_payments);
    RETURN app.sale_json(v_org, v_existing);
END;
$$;

-- Prices a cart without selling it: the same checks and the same tax engine, nothing locked and
-- nothing written. `available` is reported per line, not enforced. With p_payments it also reports
-- paid, remaining (total - paid; not 0 is fine here) and the change to give back; a store credit
-- line is checked for a customer but the balance is only reported, not reserved. A read: works in
-- an expired shop.
CREATE FUNCTION public.quote_sale(p_lines jsonb, p_customer_id uuid DEFAULT NULL, p_payments jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.current_employee_id(); v_org uuid; v_shift public.shifts; v_cart jsonb; v_total numeric;
    v_paid numeric; v_change numeric; v_balance numeric;
    v_payments jsonb := CASE WHEN p_payments = 'null'::jsonb THEN NULL ELSE p_payments END;
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
    v_total := (v_cart ->> 'total')::numeric;
    IF v_payments IS NULL THEN
        v_paid := v_total;
        v_change := 0;
    ELSE
        PERFORM app.sale_payments_check(v_org, v_shift.branch_id, p_customer_id, v_payments);
        SELECT COALESCE(sum(l.amount), 0), COALESCE(sum(l.tendered - l.amount), 0) INTO v_paid, v_change
        FROM app.sale_payments_input(v_payments) l;
    END IF;
    IF p_customer_id IS NOT NULL THEN
        SELECT COALESCE((SELECT b.balance FROM public.store_credit_balances b
                         WHERE b.customer_id = p_customer_id AND b.organization_id = v_org), 0)
        INTO v_balance;
    END IF;
    RETURN jsonb_set(v_cart, '{lines}', (
        SELECT jsonb_agg(l - 'tax_class_id' - 'unit_cost' - 'warranty_months' ORDER BY o)
        FROM jsonb_array_elements(v_cart -> 'lines') WITH ORDINALITY x(l, o)))
        || jsonb_build_object('paid', v_paid::numeric(18,2)::text,
                              'remaining', (v_total - v_paid)::numeric(18,2)::text,
                              'change', v_change::numeric(18,2)::text,
                              'store_credit_balance', v_balance::numeric(18,2)::text);
END;
$$;

-- The active banks the caller's open shift can take a transfer into: its branch's and the
-- shop-wide ones, by name only (a cashier does not see balances). No open shift: an empty list.
CREATE FUNCTION public.list_sale_payment_accounts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid := app.current_employee_id(); v_org uuid; v_shift public.shifts;
BEGIN
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('sale.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: sale.create' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.require_module('pos');
    SELECT * INTO v_shift FROM public.shifts s
    WHERE s.organization_id = v_org AND s.employee_id = v_emp AND s.status = 'open';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('items', '[]'::jsonb);
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) ORDER BY a.name, a.id)
        FROM public.cash_accounts a
        WHERE a.organization_id = v_org AND a.kind = 'bank' AND a.is_active
          AND (a.branch_id IS NULL OR a.branch_id = v_shift.branch_id)), '[]'::jsonb));
END;
$$;

-- 6. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.sale_payments_input(jsonb), app.sale_payments_check(uuid, uuid, uuid, jsonb),
    app.post_sale_payments(public.sales, public.shifts, uuid, jsonb, numeric),
    app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_sale(jsonb, text, text, uuid, jsonb), public.quote_sale(jsonb, uuid, jsonb),
    public.list_sale_payment_accounts()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_sale(jsonb, text, text, uuid, jsonb), public.quote_sale(jsonb, uuid, jsonb),
    public.list_sale_payment_accounts()
    TO authenticated;
