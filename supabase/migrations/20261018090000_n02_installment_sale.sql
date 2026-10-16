-- =============================================================================
-- N02 · Installment sale and contract (EC-81, D77)
--
-- A cashier with an open shift sells on installments in one request. In one transaction: the
-- cart is priced and the stock taken by the sale core (S01/S03), the down payment is paid by the
-- S02 payment lines, the N01 engine gives the terms for the sale total, the customer is checked
-- (national ID, status, credit R03, guarantors R04, survey R05), and the contract is written with
-- its number and its version-1 schedule, its guarantors and the credit exception it used.
-- The installment sale is a sale at a fixed deferred price, not a loan:
-- docs/ISLAMIC_FINANCE_RULES.md (binding). User-visible words say profit, never interest.
--
-- Rules (docs/tasks/N02.md, D77):
--   1. installment.create and sale.create (writes: an expired shop is refused), modules
--      installments and pos, the shop's installments switch, the caller's open shift, its device.
--   2. The cash price is the sale total (after S03 discounts, VAT as the sale stores it);
--      products.installment_price is not used.
--   3. The terms come only from app.check_installment_terms (N01); the contract and its lines
--      copy that answer. N01's commit-time triggers check them again.
--   4. Customer: the shop's (CUSTOMER_NOT_FOUND), not blocked or archived (CUSTOMER_BLOCKED),
--      with a national ID (CUSTOMER_NATIONAL_ID_REQUIRED); then credit, guarantors, survey.
--   5. app.post_sale_core gets p_pay_amount (NULL = the sale total): the down payment here; a
--      down payment of 0.00 posts no payment at all.
--   6. installment_markup_vat = taxed is refused (MARKUP_VAT_NOT_SUPPORTED) until the accountant
--      answers (D41). Contracts from orders (S10) are not made here.
--
-- Numbers: contracts 0.47.0, 2 routes. No table, column, enum or permission change.
-- =============================================================================

-- 1. The sale core, with the amount the payment lines must cover --------------------------------

DROP FUNCTION app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb, jsonb, text, uuid);

-- S03's sale core. p_pay_amount: what the payment lines cover (NULL = the sale total, as a cash
-- sale; the installment sale passes its down payment; 0 posts no payment). Unchanged otherwise.
CREATE FUNCTION app.post_sale_core(p_org uuid, p_emp uuid, p_shift public.shifts, p_lines jsonb,
                                   p_customer_id uuid, p_expected_total numeric, p_idempotency_key text,
                                   p_payments jsonb DEFAULT NULL, p_sale_discount jsonb DEFAULT NULL,
                                   p_discount_reason text DEFAULT NULL, p_discount_approval_id uuid DEFAULT NULL,
                                   p_pay_amount numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_cart jsonb; v_line jsonb; v_total numeric(18,2); v_date date; v_sale public.sales; v_line_id uuid;
    v_cost numeric := 0; v_overrides jsonb; v_paid jsonb; i integer;
    v_discount numeric; v_reason text; v_approval uuid;
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
    v_cart := app.sale_cart(p_org, p_shift.branch_id, p_lines, app.has_permission('price.override'),
                            p_sale_discount);
    v_total := (v_cart ->> 'total')::numeric;
    v_discount := (v_cart ->> 'discount_total')::numeric;
    IF v_discount > 0 THEN
        v_reason := btrim(p_discount_reason);
        IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 200 THEN
            RAISE EXCEPTION 'DISCOUNT_REASON_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        v_approval := app.check_discount_allowed(p_shift.branch_id, v_cart -> 'discount',
                          app.cart_fingerprint(p_lines, p_sale_discount), p_discount_approval_id);
    END IF;
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
                              is_b2b, prices_include_vat, subtotal, discount_total, discount_reason, tax_total,
                              total, cost_total, issued_at, business_date, idempotency_key, created_by)
    VALUES (p_org, app.next_document_number(p_org, p_shift.branch_id, 'sale'), p_shift.branch_id,
            p_shift.device_id, p_shift.id, p_customer_id, 'pos', false,
            (v_cart ->> 'prices_include_vat')::boolean, (v_cart ->> 'subtotal')::numeric, v_discount, v_reason,
            (v_cart ->> 'tax_total')::numeric, v_total, round(v_cost, 2), clock_timestamp(), v_date,
            p_idempotency_key, p_emp)
    RETURNING * INTO v_sale;

    FOR i IN 0..jsonb_array_length(v_cart -> 'lines') - 1 LOOP
        v_line := v_cart -> 'lines' -> i;
        INSERT INTO public.sale_lines (organization_id, sale_id, line_no, product_id, unit_id, quantity,
                                       unit_price, discount_amount, tax_class_id, tax_rate, tax_amount,
                                       line_total, unit_cost, warranty_until, created_by)
        VALUES (p_org, v_sale.id, i + 1, (v_line ->> 'product_id')::uuid, (v_line ->> 'unit_id')::uuid,
                (v_line ->> 'quantity')::integer, (v_line ->> 'unit_price')::numeric,
                (v_line ->> 'discount_amount')::numeric,
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

    -- The payment lines cover the sale total, or the down payment of an installment sale (N02).
    IF p_pay_amount IS NULL THEN
        v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, v_total);
    ELSIF p_pay_amount > 0 THEN
        v_paid := app.post_sale_payments(v_sale, p_shift, p_emp, p_payments, p_pay_amount);
    ELSE
        v_paid := '[]'::jsonb;
    END IF;

    -- The approval is spent by this sale, in this transaction: it can't be used again.
    IF v_approval IS NOT NULL THEN
        UPDATE public.approvals a SET entity_id = v_sale.id WHERE a.id = v_approval;
    END IF;

    SELECT jsonb_agg(jsonb_build_object('product_id', l ->> 'product_id', 'sku', l ->> 'sku',
                                        'list_price', l ->> 'list_price', 'unit_price', l ->> 'unit_price'))
    INTO v_overrides
    FROM jsonb_array_elements(v_cart -> 'lines') l WHERE (l ->> 'overridden')::boolean;
    PERFORM app.write_audit('sale.created', 'sale', v_sale.id, NULL,
        jsonb_build_object('number', v_sale.number, 'total', v_sale.total::text,
                           'tax_total', v_sale.tax_total::text,
                           'discount_total', v_sale.discount_total::text, 'discount_reason', v_sale.discount_reason,
                           'discount_approval_id', v_approval,
                           'lines', jsonb_array_length(v_cart -> 'lines'), 'customer_id', p_customer_id,
                           'shift_id', p_shift.id, 'price_overrides', COALESCE(v_overrides, '[]'::jsonb),
                           'payments', v_paid),
        NULL, v_sale.branch_id,
        CASE WHEN v_overrides IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN v_sale.id;
END;
$$;

-- 2. Helpers (schema app, no grants) -------------------------------------------------------------

-- The request body, checked for shape only (the sale core, N01 and R03-R05 check the rest).
-- Returns it normalized: guarantor_ids as a uuid array text, payments NULL when absent or empty.
CREATE FUNCTION app.installment_sale_input(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_key text; v_terms jsonb; v_ids jsonb; v_id jsonb; v_out uuid[] := ARRAY[]::uuid[];
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key NOT IN ('lines', 'expected_total', 'sale_discount', 'discount_reason', 'discount_approval_id',
                         'customer_id', 'terms', 'payments', 'guarantor_ids', 'credit_approval_id') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF jsonb_typeof(p_body -> 'expected_total') IS DISTINCT FROM 'string'
       OR (p_body ->> 'expected_total') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: expected_total' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'customer_id') IS DISTINCT FROM 'string'
       OR (p_body ->> 'customer_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: customer_id' USING ERRCODE = 'P0001';
    END IF;
    FOREACH v_key IN ARRAY ARRAY['discount_approval_id', 'credit_approval_id'] LOOP
        IF p_body ? v_key AND jsonb_typeof(p_body -> v_key) <> 'null' AND (
               jsonb_typeof(p_body -> v_key) <> 'string'
               OR (p_body ->> v_key) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF p_body ? 'discount_reason' AND jsonb_typeof(p_body -> 'discount_reason') NOT IN ('string', 'null') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: discount_reason' USING ERRCODE = 'P0001';
    END IF;
    IF p_body ? 'sale_discount' AND jsonb_typeof(p_body -> 'sale_discount') NOT IN ('object', 'null') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: sale_discount' USING ERRCODE = 'P0001';
    END IF;
    IF p_body ? 'payments' AND jsonb_typeof(p_body -> 'payments') NOT IN ('array', 'null') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payments' USING ERRCODE = 'P0001';
    END IF;

    v_terms := p_body -> 'terms';
    IF v_terms IS NULL OR jsonb_typeof(v_terms) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: terms' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(v_terms) LOOP
        IF v_key NOT IN ('down_payment', 'installments_count', 'frequency', 'first_due_date', 'policy_version') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: terms.%', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF jsonb_typeof(v_terms -> 'policy_version') IS DISTINCT FROM 'number'
       OR (v_terms ->> 'policy_version') !~ '^[1-9][0-9]{0,8}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: terms.policy_version' USING ERRCODE = 'P0001';
    END IF;

    v_ids := COALESCE(p_body -> 'guarantor_ids', '[]'::jsonb);
    IF jsonb_typeof(v_ids) <> 'array' OR jsonb_array_length(v_ids) > 3 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
    END IF;
    FOR v_id IN SELECT jsonb_array_elements(v_ids) LOOP
        IF jsonb_typeof(v_id) <> 'string'
           OR (v_id #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
        END IF;
        v_out := v_out || (v_id #>> '{}')::uuid;
    END LOOP;
    IF (SELECT count(DISTINCT i) FROM unnest(v_out) i) <> cardinality(v_out) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: guarantor_ids' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'lines', p_body -> 'lines',
        'expected_total', p_body ->> 'expected_total',
        'sale_discount', NULLIF(p_body -> 'sale_discount', 'null'::jsonb),
        'discount_reason', p_body ->> 'discount_reason',
        'discount_approval_id', p_body ->> 'discount_approval_id',
        'customer_id', p_body ->> 'customer_id',
        'payments', CASE WHEN jsonb_typeof(p_body -> 'payments') = 'array'
                              AND jsonb_array_length(p_body -> 'payments') > 0 THEN p_body -> 'payments' END,
        'guarantor_ids', to_jsonb(v_out),
        'credit_approval_id', p_body ->> 'credit_approval_id',
        'terms', v_terms);
END;
$$;

-- The Contract answer: header, customer, guarantors, the current schedule with each line's status
-- and the balance. Money as text; markup_pct as the engine gives it.
CREATE FUNCTION app.contract_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'status', c.status, 'branch_id', c.branch_id,
        'sale_id', c.sale_id, 'sale_number', s.number,
        'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1]),
        'guarantors', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', g.id, 'name', g.full_name, 'relation', cg.relation)
                             ORDER BY g.full_name, g.id)
            FROM public.contract_guarantors k
            JOIN public.guarantors g ON g.id = k.guarantor_id AND g.organization_id = k.organization_id
            LEFT JOIN public.customer_guarantors cg ON cg.guarantor_id = k.guarantor_id
                 AND cg.customer_id = c.customer_id AND cg.organization_id = k.organization_id
            WHERE k.organization_id = c.organization_id AND k.contract_id = c.id), '[]'::jsonb),
        'policy_version', p.version, 'creditor', c.creditor,
        'cash_price', c.cash_price::text, 'down_payment', c.down_payment::text,
        'financed_amount', c.financed_amount::text, 'markup_pct', trim_scale(c.markup_pct)::text,
        'markup_amount', c.markup_amount::text, 'total_payable', c.total_payable::text,
        'installments_count', c.installments_count, 'frequency', c.frequency,
        'first_due_date', c.first_due_date,
        'last_due_date', (SELECT max(l.due_date) FROM public.schedule_lines l
                          WHERE l.organization_id = c.organization_id AND l.contract_id = c.id
                            AND l.version = c.current_version),
        'current_version', c.current_version, 'credit_approval_id', c.credit_approval_id,
        'created_at', c.created_at, 'created_by_name', e.full_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'seq', ls.seq, 'due_date', ls.due_date, 'principal', ls.principal::text,
                'profit', ls.profit::text, 'amount', ls.amount::text, 'paid', ls.paid::text,
                'remaining', GREATEST(ls.remaining, 0)::numeric(18,2)::text, 'status', ls.status)
                ORDER BY ls.seq)
            FROM public.v_schedule_line_status ls
            WHERE ls.organization_id = c.organization_id AND ls.contract_id = c.id AND NOT ls.superseded), '[]'::jsonb),
        'balance', jsonb_build_object('paid', cb.paid::text, 'remaining', cb.remaining::text,
                                      'overdue', cb.overdue_amount::text))
    FROM public.contracts c
    JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
    JOIN public.installment_policies p ON p.id = c.policy_id AND p.organization_id = c.organization_id
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    LEFT JOIN public.employees e ON e.id = c.created_by AND e.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_id
$$;

-- The InstallmentSale answer.
CREATE FUNCTION app.installment_sale_json(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('sale', app.sale_json(p_org, c.sale_id), 'contract', app.contract_json(p_org, c.id))
    FROM public.contracts c WHERE c.organization_id = p_org AND c.id = p_contract_id
$$;

REVOKE ALL ON FUNCTION
    app.post_sale_core(uuid, uuid, public.shifts, jsonb, uuid, numeric, text, jsonb, jsonb, text, uuid, numeric),
    app.installment_sale_input(jsonb), app.contract_json(uuid, uuid), app.installment_sale_json(uuid, uuid)
    FROM PUBLIC, anon, authenticated;

-- 3. The installment sale ------------------------------------------------------------------------

-- A sale on installments by the caller, in their open shift (docs/tasks/N02.md decision 6 gives
-- the order). The same key again returns the first answer; a key a cash sale already used is
-- IDEMPOTENCY_CONFLICT.
CREATE FUNCTION public.post_installment_sale(p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_in jsonb; v_existing uuid; v_shift public.shifts; v_customer public.customers;
    v_terms jsonb; v_down numeric(18,2); v_financed numeric(18,2); v_policy uuid; v_approval uuid;
    v_guarantors uuid[]; v_sale public.sales; v_contract public.contracts; v_line jsonb; v_vat text;
BEGIN
    v_emp := app.require_permission('installment.create');
    PERFORM app.require_permission('sale.create');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.require_module('pos');
    IF NOT (SELECT o.installments_enabled FROM public.organizations o WHERE o.id = v_org) THEN
        RAISE EXCEPTION 'INSTALLMENTS_DISABLED' USING ERRCODE = 'P0001';
    END IF;

    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT c.id INTO v_existing FROM public.contracts c
    WHERE c.organization_id = v_org AND c.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.installment_sale_json(v_org, v_existing);    -- a repeat sells nothing
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales s WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by a sale without a contract' USING ERRCODE = 'P0001';
    END IF;

    v_in := app.installment_sale_input(p_body);
    PERFORM app.sale_lines_input(v_in -> 'lines');               -- a malformed cart stops here
    IF v_in -> 'payments' <> 'null'::jsonb THEN
        PERFORM app.sale_payments_input(v_in -> 'payments');     -- so does a malformed payment list
    END IF;
    SELECT s.installment_markup_vat INTO v_vat FROM public.org_settings s WHERE s.organization_id = v_org;
    IF v_vat = 'taxed' THEN
        RAISE EXCEPTION 'MARKUP_VAT_NOT_SUPPORTED' USING ERRCODE = 'P0001';
    END IF;

    -- The caller's open shift, locked (it can't be closed while this sale is written), on its device.
    v_shift := app.require_open_shift(v_org, v_emp);
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);
    PERFORM app.require_shift_device(v_shift.id);

    -- The customer (rule 4), before any stock is locked.
    SELECT * INTO v_customer FROM public.customers c
    WHERE c.id = (v_in ->> 'customer_id')::uuid AND c.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_customer.status = 'blocked' OR v_customer.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    IF NULLIF(btrim(v_customer.national_id), '') IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NATIONAL_ID_REQUIRED' USING ERRCODE = 'P0001';
    END IF;

    -- The terms for the cash price the cashier saw; the sale core refuses PRICE_CHANGED when the
    -- server's total differs, so the contract's cash price is always the sale total.
    v_terms := app.check_installment_terms(v_org,
        jsonb_strip_nulls(jsonb_build_object(
            'cash_price', v_in ->> 'expected_total',
            'down_payment', v_in -> 'terms' -> 'down_payment',
            'installments_count', v_in -> 'terms' -> 'installments_count',
            'frequency', v_in -> 'terms' -> 'frequency',
            'first_due_date', v_in -> 'terms' -> 'first_due_date')),
        (v_in -> 'terms' ->> 'policy_version')::integer);
    v_down := (v_terms ->> 'down_payment')::numeric;
    v_financed := (v_terms ->> 'financed_amount')::numeric;
    v_policy := (v_terms ->> 'policy_id')::uuid;
    IF v_down = 0 AND v_in -> 'payments' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payments (no down payment)' USING ERRCODE = 'P0001';
    END IF;

    -- Credit (locks the customer: two tills take turns), guarantors, survey.
    v_approval := app.check_customer_credit(v_org, v_customer.id, v_financed,
                                            (v_in ->> 'credit_approval_id')::uuid);
    SELECT COALESCE(array_agg(i::uuid), ARRAY[]::uuid[]) INTO v_guarantors
    FROM jsonb_array_elements_text(v_in -> 'guarantor_ids') i;
    PERFORM app.check_contract_guarantors(v_org, v_customer.id, v_policy, v_financed, v_guarantors);
    PERFORM app.check_contract_survey(v_org, v_customer.id, v_policy, v_financed);

    -- The sale: goods, tax, stock and the down payment (rule 5).
    v_existing := app.post_sale_core(
        v_org, v_emp, v_shift, v_in -> 'lines', v_customer.id, (v_in ->> 'expected_total')::numeric,
        p_idempotency_key, NULLIF(v_in -> 'payments', 'null'::jsonb),
        NULLIF(v_in -> 'sale_discount', 'null'::jsonb), v_in ->> 'discount_reason',
        (v_in ->> 'discount_approval_id')::uuid, v_down);
    SELECT * INTO v_sale FROM public.sales s WHERE s.id = v_existing;

    -- The contract and its version-1 schedule, exactly as the engine gave them.
    INSERT INTO public.contracts (organization_id, number, customer_id, branch_id, sale_id, policy_id, cash_price,
                                  down_payment, financed_amount, markup_pct, markup_amount, total_payable,
                                  installments_count, frequency, first_due_date, credit_approval_id,
                                  idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_shift.branch_id, 'contract'), v_customer.id, v_shift.branch_id,
            v_sale.id, v_policy, v_sale.total, v_down, v_financed, (v_terms ->> 'markup_pct')::numeric,
            (v_terms ->> 'markup_amount')::numeric, (v_terms ->> 'total_payable')::numeric,
            (v_terms ->> 'installments_count')::integer, (v_terms ->> 'frequency')::public.installment_frequency,
            (v_terms ->> 'first_due_date')::date, v_approval, p_idempotency_key, v_emp)
    RETURNING * INTO v_contract;
    FOR v_line IN SELECT jsonb_array_elements(v_terms -> 'lines') LOOP
        INSERT INTO public.schedule_lines (organization_id, contract_id, version, seq, due_date, principal, profit,
                                           created_by)
        VALUES (v_org, v_contract.id, 1, (v_line ->> 'seq')::integer, (v_line ->> 'due_date')::date,
                (v_line ->> 'principal')::numeric, (v_line ->> 'profit')::numeric, v_emp);
    END LOOP;
    PERFORM app.attach_contract_guarantors(v_org, v_contract.id, v_guarantors);
    IF v_approval IS NOT NULL THEN
        PERFORM app.use_credit_approval(v_approval, v_contract.id);
    END IF;

    PERFORM app.write_audit('contract.created', 'contract', v_contract.id, NULL,
        jsonb_build_object('number', v_contract.number, 'sale_number', v_sale.number,
                           'customer_id', v_customer.id, 'cash_price', v_contract.cash_price::text,
                           'down_payment', v_contract.down_payment::text,
                           'financed_amount', v_contract.financed_amount::text,
                           'markup_pct', v_terms ->> 'markup_pct', 'markup_amount', v_contract.markup_amount::text,
                           'total_payable', v_contract.total_payable::text,
                           'installments_count', v_contract.installments_count, 'frequency', v_contract.frequency,
                           'first_due_date', v_terms ->> 'first_due_date', 'last_due_date', v_terms ->> 'last_due_date',
                           'policy_version', v_terms -> 'policy_version', 'guarantor_ids', to_jsonb(v_guarantors),
                           'credit_approval_id', v_approval),
        NULL, v_contract.branch_id,
        CASE WHEN v_approval IS NULL THEN 'info' ELSE 'warning' END::public.audit_severity);

    RETURN app.installment_sale_json(v_org, v_contract.id);
END;
$$;

-- 4. Reading a contract --------------------------------------------------------------------------

-- Any customer read key (R01's guard: an expired shop may read) and the contract's branch among
-- the caller's branches; otherwise, and for another shop's id, CONTRACT_NOT_FOUND.
CREATE FUNCTION public.get_contract(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    SELECT c.branch_id INTO v_branch FROM public.contracts c WHERE c.organization_id = v_org AND c.id = p_id;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.contract_json(v_org, p_id);
END;
$$;

REVOKE ALL ON FUNCTION public.post_installment_sale(jsonb, text), public.get_contract(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_installment_sale(jsonb, text), public.get_contract(uuid) TO authenticated;
