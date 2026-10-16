-- =============================================================================
-- N03 · Collections (installment payments) (EC-82, D78)
--
-- A cashier at any branch takes a payment on one or several contracts of one customer in one
-- request, split across cash and bank transfers. In one transaction the contracts are locked,
-- the amount of each contract is allocated to its current schedule oldest line first (profit,
-- then principal), the payment rows are written under one receipt, the cash goes into the drawer
-- of the shift that took it, and a contract with nothing left is completed. A wrong collection
-- can be reversed on its own business day. A collection is not a sale: no revenue, no VAT.
-- Islamic finance (docs/ISLAMIC_FINANCE_RULES.md, binding): no late fee or penalty of any kind
-- (rule 4, 16 Oct): charges are never read or paid here. User-visible words say profit.
--
-- Rules (docs/tasks/N03.md, D78):
--   1. collection.create, module installments, the caller's open shift and its device. The
--      contracts may belong to any branch; the payment belongs to the shift's branch.
--   2. Body: customer_id, contracts [{contract_id, amount, expected_remaining?}] (1-10), payment
--      lines (S02's shape without store credit, 1-4). Lines add up to the contracts' amounts.
--   3. A contract's amount never exceeds what is left on it (no overpayment, no store credit).
--   4. Allocation: app.collection_allocation, the same for the preview and the write.
--   5. payments.collection_id ties the rows of one collection to its first row (the receipt).
--   6. Reversal (collection.reverse): same business day, the latest collection of every contract
--      it paid, the collection's shift still open; money back from the same accounts.
--   7. Holders of collection.create / collection.reverse see every contract of the shop.
--
-- Numbers: contracts 0.48.0, 6 routes. Schema: payments.collection_id; permission
-- collection.reverse (OWNER always, BRANCH_MANAGER by default, grantable per employee).
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

ALTER TABLE public.payments ADD COLUMN collection_id uuid;
ALTER TABLE public.payments ADD CONSTRAINT payments_collection_fk
    FOREIGN KEY (collection_id, organization_id) REFERENCES public.payments (id, organization_id);
CREATE INDEX payments_collection_idx ON public.payments (organization_id, collection_id)
    WHERE collection_id IS NOT NULL;

INSERT INTO public.permissions (key, module, description) VALUES
    ('collection.reverse',       'installments', 'Reverse a same-day collection');
INSERT INTO public.role_permissions (role, permission_key) VALUES
    ('BRANCH_MANAGER', 'collection.reverse');

-- 2. Helpers (schema app, no grants) -----------------------------------------------------------------

-- Who sees a contract (owner decision 9): the collection keys see every branch of the shop;
-- anyone else only the branches they work in.
CREATE FUNCTION app.can_see_contract(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('collection.create') OR app.has_permission('collection.reverse')
        OR app.has_branch_access(p_branch_id)
$$;

-- The request body, checked for shape only. Returns it normalized: contracts with their amounts
-- as text (2 decimals), the payment lines as given, the total of the contracts.
CREATE FUNCTION app.collection_input(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_key text; v_c jsonb; v_out jsonb := '[]'::jsonb; v_ids uuid[] := ARRAY[]::uuid[];
    v_total numeric := 0; v_exp text; i integer;
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key NOT IN ('customer_id', 'contracts', 'payments') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    IF jsonb_typeof(p_body -> 'customer_id') IS DISTINCT FROM 'string'
       OR (p_body ->> 'customer_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: customer_id' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'contracts') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_body -> 'contracts') NOT BETWEEN 1 AND 10 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: contracts' USING ERRCODE = 'P0001';
    END IF;
    FOR i IN 0..jsonb_array_length(p_body -> 'contracts') - 1 LOOP
        v_c := p_body -> 'contracts' -> i;
        IF jsonb_typeof(v_c) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_c) k
                      WHERE k NOT IN ('contract_id', 'amount', 'expected_remaining'))
           OR jsonb_typeof(v_c -> 'contract_id') IS DISTINCT FROM 'string'
           OR (v_c ->> 'contract_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           OR jsonb_typeof(v_c -> 'amount') IS DISTINCT FROM 'string'
           OR (v_c ->> 'amount') !~ '^\d{1,16}(\.\d{1,2})?$' OR (v_c ->> 'amount')::numeric <= 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: contract %', i + 1 USING ERRCODE = 'P0001';
        END IF;
        v_exp := NULL;
        IF v_c ? 'expected_remaining' AND jsonb_typeof(v_c -> 'expected_remaining') <> 'null' THEN
            IF jsonb_typeof(v_c -> 'expected_remaining') <> 'string'
               OR (v_c ->> 'expected_remaining') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: contract % expected_remaining', i + 1 USING ERRCODE = 'P0001';
            END IF;
            v_exp := ((v_c ->> 'expected_remaining')::numeric(18,2))::text;
        END IF;
        IF (v_c ->> 'contract_id')::uuid = ANY (v_ids) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: contract % is listed twice', i + 1 USING ERRCODE = 'P0001';
        END IF;
        v_ids := v_ids || (v_c ->> 'contract_id')::uuid;
        v_total := v_total + (v_c ->> 'amount')::numeric;
        v_out := v_out || jsonb_build_object('contract_id', v_c ->> 'contract_id',
                                             'amount', ((v_c ->> 'amount')::numeric(18,2))::text,
                                             'expected_remaining', v_exp);
    END LOOP;

    -- S02's payment line shape, then: no store credit, at most 4 lines.
    IF jsonb_typeof(p_body -> 'payments') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_body -> 'payments') NOT BETWEEN 1 AND 4 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: payments' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM app.sale_payments_input(p_body -> 'payments') l WHERE l.method = 'store_credit') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: store credit is not a collection method' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object('customer_id', p_body ->> 'customer_id', 'contracts', v_out,
                              'payments', p_body -> 'payments', 'total', (v_total::numeric(18,2))::text);
END;
$$;

-- What is due on a contract's current schedule: the due summary and its lines. No fee fields
-- (rule 4). Money as text.
CREATE FUNCTION app.contract_due(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH l AS (
        SELECT ls.*, GREATEST(ls.remaining, 0)::numeric(18,2) AS left_amount
        FROM public.v_schedule_line_status ls
        JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
        WHERE ls.organization_id = p_org AND ls.contract_id = p_contract_id
          AND NOT ls.superseded AND ls.version = c.current_version
    ), n AS (SELECT min(due_date) AS d FROM l WHERE left_amount > 0)
    SELECT jsonb_build_object(
        'due', jsonb_build_object(
            'overdue_amount', COALESCE(sum(l.left_amount) FILTER (WHERE l.status = 'overdue'), 0)::numeric(18,2)::text,
            'overdue_lines', count(*) FILTER (WHERE l.status = 'overdue'),
            'due_today', COALESCE(sum(l.left_amount) FILTER (WHERE l.status = 'due'), 0)::numeric(18,2)::text,
            'next_due_date', (SELECT d FROM n),
            'next_due_amount', COALESCE(sum(l.left_amount) FILTER (WHERE l.due_date = (SELECT d FROM n)), 0)::numeric(18,2)::text,
            'remaining', COALESCE(sum(l.left_amount), 0)::numeric(18,2)::text),
        'lines', COALESCE(jsonb_agg(jsonb_build_object(
            'seq', l.seq, 'due_date', l.due_date, 'amount', l.amount::text, 'paid', l.paid::text,
            'remaining', l.left_amount::text, 'status', l.status,
            'days_late', CASE WHEN l.status = 'overdue' THEN l.days_late ELSE 0 END) ORDER BY l.seq), '[]'::jsonb))
    FROM l
$$;

-- The allocation of p_amount to a contract (decision 4): its current schedule, lines in seq
-- order, profit first then principal, the next line only when this one is paid. Effective
-- allocations only (a reversed payment never counts). Charges are never paid (rule 4). What is
-- left when every line is paid is not allocated: the caller refuses it.
CREATE FUNCTION app.collection_allocation(p_org uuid, p_contract_id uuid, p_amount numeric)
RETURNS TABLE (schedule_line_id uuid, seq integer, due_date date, profit numeric, principal numeric,
               amount numeric, pays_off boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_left numeric := p_amount; v_p numeric; v_q numeric;
BEGIN
    FOR r IN
        SELECT ls.schedule_line_id AS id, ls.seq, ls.due_date, ls.remaining,
               GREATEST(ls.profit - ls.paid_profit, 0) AS profit_left,
               GREATEST(ls.principal - ls.paid_principal, 0) AS principal_left
        FROM public.v_schedule_line_status ls
        JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
        WHERE ls.organization_id = p_org AND ls.contract_id = p_contract_id
          AND NOT ls.superseded AND ls.version = c.current_version AND ls.remaining > 0
        ORDER BY ls.seq
    LOOP
        EXIT WHEN v_left <= 0;
        v_p := LEAST(v_left, r.profit_left);
        v_q := LEAST(v_left - v_p, r.principal_left);
        v_left := v_left - v_p - v_q;
        CONTINUE WHEN v_p + v_q <= 0;
        schedule_line_id := r.id; seq := r.seq; due_date := r.due_date;
        profit := v_p::numeric(18,2); principal := v_q::numeric(18,2); amount := (v_p + v_q)::numeric(18,2);
        pays_off := v_p + v_q >= r.remaining;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- The current remaining of a contract (its current schedule, effective allocations only).
CREATE FUNCTION app.contract_remaining(p_org uuid, p_contract_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(sum(GREATEST(ls.remaining, 0)), 0)::numeric(18,2)
    FROM public.v_schedule_line_status ls
    JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
    WHERE ls.organization_id = p_org AND ls.contract_id = p_contract_id
      AND NOT ls.superseded AND ls.version = c.current_version
$$;

-- The Collection answer (the receipt). The per-contract allocation and balance after the
-- collection are the ones stored in its collection.created audit row; the status is today's.
CREATE FUNCTION app.collection_json(p_org uuid, p_receipt_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', p.id, 'number', p.number, 'business_date', p.business_date, 'paid_at', p.paid_at,
        'received_by_name', e.full_name, 'branch_id', p.branch_id, 'branch_name', b.name,
        'shift_id', p.shift_id,
        'amount', (SELECT sum(x.amount) FROM public.payments x
                   WHERE x.organization_id = p_org AND x.collection_id = p.id)::numeric(18,2)::text,
        'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1]),
        'payments', (SELECT jsonb_agg(jsonb_build_object(
                         'id', x.id, 'number', x.number, 'method', x.method, 'amount', x.amount::text,
                         'tendered', x.tendered::text,
                         'change', CASE WHEN x.tendered IS NOT NULL THEN (x.tendered - x.amount)::numeric(18,2)::text END,
                         'reference', x.reference, 'cash_account_id', x.cash_account_id)
                         ORDER BY x.number, x.id)
                     FROM public.payments x WHERE x.organization_id = p_org AND x.collection_id = p.id),
        'contracts', (SELECT jsonb_agg(e.val || jsonb_build_object('status', c.status) ORDER BY e.ord)
                      FROM jsonb_array_elements(a.after -> 'contracts') WITH ORDINALITY AS e(val, ord)
                      JOIN public.contracts c ON c.id = (e.val ->> 'id')::uuid AND c.organization_id = p_org),
        'reversal', (SELECT jsonb_build_object('id', r.id, 'number', r.number, 'reversed_at', r.paid_at,
                                               'reversed_by_name', re.full_name, 'reason', r.reason)
                     FROM public.payments r
                     LEFT JOIN public.employees re ON re.id = r.created_by AND re.organization_id = p_org
                     WHERE r.organization_id = p_org AND r.reverses_payment_id = p.id),
        'receipt_prints', (SELECT count(*) FROM public.audit_log l
                           WHERE l.organization_id = p_org AND l.entity_type = 'payment' AND l.entity_id = p.id
                             AND l.action = 'collection.receipt_printed'))
    FROM public.payments p
    JOIN public.customers cu ON cu.id = p.customer_id AND cu.organization_id = p.organization_id
    JOIN public.branches b ON b.id = p.branch_id AND b.organization_id = p.organization_id
    LEFT JOIN public.employees e ON e.id = p.received_by AND e.organization_id = p.organization_id
    LEFT JOIN LATERAL (SELECT l.after FROM public.audit_log l
                       WHERE l.organization_id = p_org AND l.entity_type = 'payment' AND l.entity_id = p.id
                         AND l.action = 'collection.created' ORDER BY l.created_at LIMIT 1) a ON true
    WHERE p.organization_id = p_org AND p.id = p_receipt_id
$$;

-- The receipt row of a collection (its first payment row), or NULL.
CREATE FUNCTION app.collection_receipt(p_org uuid, p_id uuid)
RETURNS public.payments LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT p.* FROM public.payments p
    WHERE p.organization_id = p_org AND p.id = p_id AND p.collection_id = p.id
      AND p.direction = 'in' AND p.reverses_payment_id IS NULL
$$;

-- The collection itself (decisions 2-9, 17), after the caller checked the key, the shift and the
-- body. p_shift NULL and p_cash_account = a collector wallet is N06's call (not built). Returns
-- the receipt id.
CREATE FUNCTION app.post_collection_core(p_org uuid, p_emp uuid, p_branch uuid, p_shift public.shifts,
                                         p_cash_account uuid, p_in jsonb, p_key text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_customer public.customers; v_c jsonb; v_contract public.contracts; v_remaining numeric;
    v_amount numeric; v_paid numeric; r record; a record; v_date date := app.org_today(p_org);
    v_receipt uuid := gen_random_uuid(); v_number text; v_pid uuid; v_account uuid; i integer;
    -- Allocation pieces (contract by contract, line by line) and the payment rows' capacity.
    s_line uuid[] := '{}'; s_contract uuid[] := '{}'; s_profit numeric[] := '{}'; s_principal numeric[] := '{}';
    p_ids uuid[] := '{}'; p_left numeric[] := '{}'; si integer := 1; pj integer := 1;
    v_take numeric; v_tp numeric; v_tq numeric;
    v_after jsonb := '[]'::jsonb; v_lines jsonb; v_due jsonb; v_numbers text; v_completed uuid[] := '{}';
    v_posted jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_customer FROM public.customers c
    WHERE c.id = (p_in ->> 'customer_id')::uuid AND c.organization_id = p_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    -- The contracts, locked in id order so two tills paying overlapping sets never deadlock.
    PERFORM 1 FROM public.contracts c
    WHERE c.organization_id = p_org AND c.customer_id = v_customer.id
      AND c.id IN (SELECT (x ->> 'contract_id')::uuid FROM jsonb_array_elements(p_in -> 'contracts') x)
    ORDER BY c.id FOR UPDATE;

    FOR v_c IN SELECT x FROM jsonb_array_elements(p_in -> 'contracts') x LOOP
        SELECT * INTO v_contract FROM public.contracts c
        WHERE c.id = (v_c ->> 'contract_id')::uuid AND c.organization_id = p_org AND c.customer_id = v_customer.id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('contract_id', v_c ->> 'contract_id')::text;
        END IF;
        v_remaining := app.contract_remaining(p_org, v_contract.id);
        IF v_contract.status NOT IN ('active', 'rescheduled') OR v_remaining <= 0 THEN
            RAISE EXCEPTION 'CONTRACT_NOT_OPEN: %', v_contract.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('contract_id', v_contract.id, 'status', v_contract.status)::text;
        END IF;
        IF v_c ->> 'expected_remaining' IS NOT NULL AND (v_c ->> 'expected_remaining')::numeric <> v_remaining THEN
            RAISE EXCEPTION 'COLLECTION_DUE_CHANGED: % has % left', v_contract.number, v_remaining USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('contract_id', v_contract.id, 'remaining', v_remaining::text)::text;
        END IF;
        v_amount := (v_c ->> 'amount')::numeric;
        IF v_amount > v_remaining THEN
            RAISE EXCEPTION 'COLLECTION_EXCEEDS_REMAINING: % has % left', v_contract.number, v_remaining
                USING ERRCODE = 'P0001',
                      DETAIL = jsonb_build_object('contract_id', v_contract.id, 'remaining', v_remaining::text)::text;
        END IF;
        FOR a IN SELECT * FROM app.collection_allocation(p_org, v_contract.id, v_amount) LOOP
            s_line := s_line || a.schedule_line_id; s_contract := s_contract || v_contract.id;
            s_profit := s_profit || a.profit; s_principal := s_principal || a.principal;
        END LOOP;
    END LOOP;

    -- The payment lines cover the contracts' amounts exactly; bank accounts are checked as S02 does.
    SELECT COALESCE(sum(l.amount), 0) INTO v_paid FROM app.sale_payments_input(p_in -> 'payments') l;
    IF v_paid <> (p_in ->> 'total')::numeric THEN
        RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH: the payments add up to %, the contracts to %', v_paid, p_in ->> 'total'
            USING ERRCODE = 'P0001',
                  DETAIL = jsonb_build_object('total', p_in ->> 'total', 'paid', v_paid::numeric(18,2)::text)::text;
    END IF;
    PERFORM app.sale_payments_check(p_org, p_branch, v_customer.id, p_in -> 'payments');
    PERFORM 1 FROM public.cash_accounts ca
    WHERE ca.organization_id = p_org
      AND ca.id IN (SELECT l.cash_account_id FROM app.sale_payments_input(p_in -> 'payments') l
                    WHERE l.cash_account_id IS NOT NULL)
    ORDER BY ca.id FOR SHARE;

    SELECT string_agg(c.number, ', ' ORDER BY x.ord) INTO v_numbers
    FROM jsonb_array_elements(p_in -> 'contracts') WITH ORDINALITY AS x(x, ord)
    JOIN public.contracts c ON c.id = (x.x ->> 'contract_id')::uuid AND c.organization_id = p_org;

    -- Everything is checked: the payment rows (the first is the receipt), then the allocations.
    FOR r IN SELECT * FROM app.sale_payments_input(p_in -> 'payments') ORDER BY line_no LOOP
        v_pid := CASE WHEN r.line_no = 1 THEN v_receipt ELSE gen_random_uuid() END;
        v_account := CASE r.method WHEN 'cash' THEN p_cash_account ELSE r.cash_account_id END;
        v_number := app.next_document_number(p_org, p_branch, 'payment');
        INSERT INTO public.payments (id, organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, reference, tendered, received_by, paid_at, business_date,
                                     idempotency_key, collection_id, created_by)
        VALUES (v_pid, p_org, v_number, p_branch, 'in', r.method::public.payment_method, r.amount, v_customer.id,
                v_account, p_shift.id, r.reference, r.tendered, p_emp, clock_timestamp(), v_date,
                CASE WHEN r.line_no = 1 THEN p_key ELSE 'system:collection:' || v_receipt::text || ':' || r.line_no END,
                v_receipt, p_emp);
        p_ids := p_ids || v_pid; p_left := p_left || r.amount;
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                           source_type, source_id, note, business_date, created_by, created_at)
        VALUES (p_org, v_account, p_branch, CASE WHEN r.method = 'cash' THEN p_shift.id END, r.amount, 'collection',
                'payment', v_pid, left(concat_ws(' ', v_number, v_numbers, r.reference), 200), v_date, p_emp,
                clock_timestamp());
        v_posted := v_posted || jsonb_build_object('method', r.method, 'amount', r.amount::numeric(18,2)::text,
                                                   'cash_account_id', v_account, 'reference', r.reference);
    END LOOP;

    -- Spread the pieces over the payment rows in order (decision 5): profit before principal.
    WHILE si <= cardinality(s_line) LOOP
        v_take := LEAST(s_profit[si] + s_principal[si], p_left[pj]);
        v_tp := LEAST(v_take, s_profit[si]);
        v_tq := v_take - v_tp;
        INSERT INTO public.payment_allocations (organization_id, payment_id, amount, schedule_line_id, contract_id,
                                                principal_amount, profit_amount, created_by)
        VALUES (p_org, p_ids[pj], v_take, s_line[si], s_contract[si], v_tq, v_tp, p_emp);
        s_profit[si] := s_profit[si] - v_tp; s_principal[si] := s_principal[si] - v_tq;
        p_left[pj] := p_left[pj] - v_take;
        IF s_profit[si] + s_principal[si] = 0 THEN si := si + 1; END IF;
        IF p_left[pj] = 0 THEN pj := pj + 1; END IF;
    END LOOP;

    -- Per contract: completion (decision 9) and what the receipt shows.
    FOR v_c IN SELECT x FROM jsonb_array_elements(p_in -> 'contracts') x LOOP
        SELECT * INTO v_contract FROM public.contracts c
        WHERE c.id = (v_c ->> 'contract_id')::uuid AND c.organization_id = p_org;
        SELECT jsonb_agg(jsonb_build_object('seq', l.seq, 'due_date', l.due_date,
                   'profit', sum_p::numeric(18,2)::text, 'principal', sum_q::numeric(18,2)::text,
                   'amount', (sum_p + sum_q)::numeric(18,2)::text, 'pays_off', ls.remaining <= 0) ORDER BY l.seq)
        INTO v_lines
        FROM (SELECT pa.schedule_line_id, sum(pa.profit_amount) sum_p, sum(pa.principal_amount) sum_q
              FROM public.payment_allocations pa
              WHERE pa.organization_id = p_org AND pa.payment_id = ANY (p_ids) AND pa.contract_id = v_contract.id
              GROUP BY pa.schedule_line_id) g
        JOIN public.schedule_lines l ON l.id = g.schedule_line_id
        JOIN public.v_schedule_line_status ls ON ls.schedule_line_id = g.schedule_line_id;
        v_remaining := app.contract_remaining(p_org, v_contract.id);
        IF v_remaining = 0 THEN
            UPDATE public.contracts c SET status = 'completed', closed_at = now(), updated_at = now(), updated_by = p_emp
            WHERE c.id = v_contract.id;
            v_completed := v_completed || v_contract.id;
        END IF;
        v_due := app.contract_due(p_org, v_contract.id) -> 'due';
        v_after := v_after || jsonb_build_object(
            'id', v_contract.id, 'number', v_contract.number, 'amount', v_c ->> 'amount',
            'allocation', jsonb_build_object('lines', COALESCE(v_lines, '[]'::jsonb), 'completes_contract', v_remaining = 0),
            'after', jsonb_build_object('remaining', v_due ->> 'remaining', 'next_due_date', v_due -> 'next_due_date',
                                        'next_due_amount', v_due ->> 'next_due_amount'));
    END LOOP;

    PERFORM app.write_audit('collection.created', 'payment', v_receipt, NULL,
        jsonb_build_object('number', (SELECT p.number FROM public.payments p WHERE p.id = v_receipt),
                           'customer_id', v_customer.id, 'total', p_in ->> 'total', 'shift_id', p_shift.id,
                           'payments', v_posted, 'contracts', v_after),
        NULL, p_branch, 'info');
    FOR i IN 1..cardinality(v_completed) LOOP
        PERFORM app.write_audit('contract.completed', 'contract', v_completed[i], NULL,
            jsonb_build_object('number', (SELECT c.number FROM public.contracts c WHERE c.id = v_completed[i]),
                               'collection_id', v_receipt),
            NULL, p_branch, 'info');
    END LOOP;
    RETURN v_receipt;
END;
$$;

REVOKE ALL ON FUNCTION
    app.can_see_contract(uuid), app.collection_input(jsonb), app.contract_due(uuid, uuid),
    app.collection_allocation(uuid, uuid, numeric), app.contract_remaining(uuid, uuid),
    app.collection_json(uuid, uuid), app.collection_receipt(uuid, uuid),
    app.post_collection_core(uuid, uuid, uuid, public.shifts, uuid, jsonb, text)
    FROM PUBLIC, anon, authenticated;

-- 3. Taking a collection -----------------------------------------------------------------------------

-- A collection by the caller in their open shift (docs/tasks/N03.md decision 7 gives the order).
-- The same key again returns the first answer; a key another payment or a sale used is
-- IDEMPOTENCY_CONFLICT.
CREATE FUNCTION public.post_collection(p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_in jsonb; v_existing public.payments; v_shift public.shifts; v_receipt uuid;
BEGIN
    v_emp := app.require_permission('collection.create');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');

    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_existing FROM public.payments p
    WHERE p.organization_id = v_org AND p.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_existing.collection_id = v_existing.id AND v_existing.direction = 'in' THEN
            RETURN app.collection_json(v_org, v_existing.id);    -- a repeat collects nothing
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another payment' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales s WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by a sale' USING ERRCODE = 'P0001';
    END IF;

    v_in := app.collection_input(p_body);

    -- The caller's open shift, locked (it can't be closed while this is written), on its device.
    v_shift := app.require_open_shift(v_org, v_emp);
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
    IF v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'SHIFT_CLOSED: the shift is closed' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_shift.branch_id);
    PERFORM app.require_shift_device(v_shift.id);

    v_receipt := app.post_collection_core(v_org, v_emp, v_shift.branch_id, v_shift, v_shift.drawer_account_id,
                                          v_in, p_idempotency_key);
    RETURN app.collection_json(v_org, v_receipt);
END;
$$;

-- 4. Reversing a collection (decision 11) -------------------------------------------------------------

CREATE FUNCTION public.reverse_collection(p_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_receipt public.payments; v_existing public.payments; v_shift public.shifts;
    v_reason text; v_date date; v_first uuid := gen_random_uuid(); v_rid uuid; v_n integer := 0;
    pay public.payments; cm public.cash_movements; c public.contracts; v_later uuid; v_status public.contract_status;
    v_contracts jsonb := '[]'::jsonb; v_reopened uuid[] := '{}'; i integer;
BEGIN
    v_emp := app.require_permission('collection.reverse');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) k WHERE k <> 'reason')
       OR jsonb_typeof(p_body -> 'reason') IS DISTINCT FROM 'string'
       OR length(btrim(p_body ->> 'reason')) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    v_reason := btrim(p_body ->> 'reason');

    v_receipt := app.collection_receipt(v_org, p_id);
    IF v_receipt.id IS NULL THEN
        RAISE EXCEPTION 'COLLECTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.payments p WHERE p.id = v_receipt.id FOR UPDATE;
    PERFORM app.require_branch_access(v_receipt.branch_id);

    SELECT * INTO v_existing FROM public.payments p
    WHERE p.organization_id = v_org AND p.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_existing.reverses_payment_id = v_receipt.id THEN
            RETURN app.collection_json(v_org, v_receipt.id);    -- a repeat reverses nothing
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another payment' USING ERRCODE = 'P0001';
    END IF;

    IF EXISTS (SELECT 1 FROM public.payments r WHERE r.organization_id = v_org AND r.reverses_payment_id = v_receipt.id) THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: already reversed' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'already_reversed')::text;
    END IF;
    v_date := app.org_today(v_org);
    IF v_receipt.business_date <> v_date THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: not the same day' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'not_same_day')::text;
    END IF;
    -- The money goes back out of the drawer that took it: that shift must still be open.
    SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_receipt.shift_id AND s.organization_id = v_org FOR UPDATE;
    IF v_shift.id IS NULL OR v_shift.status <> 'open' THEN
        RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: the shift is closed' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('reason', 'shift_closed')::text;
    END IF;
    PERFORM app.require_shift_device(v_shift.id);

    -- Every contract it paid, locked; it must be the latest effective collection on each.
    FOR c IN SELECT k.* FROM public.contracts k
             WHERE k.organization_id = v_org
               AND k.id IN (SELECT pa.contract_id FROM public.payment_allocations pa
                            JOIN public.payments p ON p.id = pa.payment_id
                            WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)
             ORDER BY k.id FOR UPDATE LOOP
        SELECT p.collection_id INTO v_later FROM public.v_effective_allocations ea
        JOIN public.payments p ON p.id = ea.payment_id
        WHERE ea.organization_id = v_org AND ea.contract_id = c.id AND p.collection_id <> v_receipt.id
          AND p.paid_at > v_receipt.paid_at
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: a later collection on %', c.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'not_latest', 'contract_id', c.id)::text;
        END IF;
    END LOOP;

    -- One reversing row per payment row (the first carries the key), the money back out.
    FOR pay IN SELECT p.* FROM public.payments p
               WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id
               ORDER BY (p.id = v_receipt.id) DESC, p.number, p.id LOOP
        v_n := v_n + 1;
        v_rid := CASE WHEN v_n = 1 THEN v_first ELSE gen_random_uuid() END;
        INSERT INTO public.payments (id, organization_id, number, branch_id, direction, method, amount, customer_id,
                                     cash_account_id, shift_id, reference, received_by, paid_at, business_date,
                                     reverses_payment_id, reason, idempotency_key, collection_id, created_by)
        VALUES (v_rid, v_org, app.next_document_number(v_org, pay.branch_id, 'payment'), pay.branch_id, 'out',
                pay.method, pay.amount, pay.customer_id, pay.cash_account_id, pay.shift_id, pay.reference, v_emp,
                clock_timestamp(), v_date, pay.id, v_reason,
                CASE WHEN v_n = 1 THEN p_idempotency_key ELSE 'system:collection-reversal:' || v_first::text || ':' || v_n END,
                v_first, v_emp);
        FOR cm IN SELECT m.* FROM public.cash_movements m
                  WHERE m.organization_id = v_org AND m.source_type = 'payment' AND m.source_id = pay.id
                    AND m.type = 'collection' ORDER BY m.id LOOP
            INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                               source_type, source_id, reverses_movement_id, note, business_date,
                                               created_by, created_at)
            VALUES (v_org, cm.cash_account_id, cm.branch_id, cm.shift_id, -cm.amount, 'collection', 'payment', v_rid,
                    cm.id, left(v_reason, 200), v_date, v_emp, clock_timestamp());
        END LOOP;
    END LOOP;

    -- A contract this collection completed is open again.
    FOR c IN SELECT k.* FROM public.contracts k
             WHERE k.organization_id = v_org
               AND k.id IN (SELECT pa.contract_id FROM public.payment_allocations pa
                            JOIN public.payments p ON p.id = pa.payment_id
                            WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)
             ORDER BY k.id LOOP
        v_status := c.status;
        IF c.status = 'completed' THEN
            v_status := CASE WHEN c.current_version > 1 THEN 'rescheduled' ELSE 'active' END;
            UPDATE public.contracts k SET status = v_status, closed_at = NULL, updated_at = now(), updated_by = v_emp
            WHERE k.id = c.id;
            v_reopened := v_reopened || c.id;
        END IF;
        v_contracts := v_contracts || jsonb_build_object('id', c.id, 'number', c.number, 'status_before', c.status,
            'status_after', v_status, 'remaining_after', app.contract_remaining(v_org, c.id)::text);
    END LOOP;

    PERFORM app.write_audit('collection.reversed', 'payment', v_receipt.id, NULL,
        jsonb_build_object('number', v_receipt.number,
                           'reversal_number', (SELECT p.number FROM public.payments p WHERE p.id = v_first),
                           'amount', (SELECT sum(p.amount) FROM public.payments p
                                      WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id)::numeric(18,2)::text,
                           'contracts', v_contracts),
        v_reason, v_receipt.branch_id, 'warning');
    FOR i IN 1..cardinality(v_reopened) LOOP
        PERFORM app.write_audit('contract.reopened', 'contract', v_reopened[i], NULL,
            jsonb_build_object('number', (SELECT k.number FROM public.contracts k WHERE k.id = v_reopened[i]),
                               'collection_id', v_receipt.id),
            v_reason, v_receipt.branch_id, 'warning');
    END LOOP;
    RETURN app.collection_json(v_org, v_receipt.id);
END;
$$;

-- 5. Reads ---------------------------------------------------------------------------------------------

-- What is due on a contract and what an amount would pay (decision 12). collection.create, read
-- with has_permission (an expired shop may look).
CREATE FUNCTION public.preview_collection(p_contract_id uuid, p_amount_text text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; c public.contracts; v_due jsonb; v_remaining numeric; v_alloc jsonb; p_amount numeric;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('collection.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: collection.create' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    SELECT * INTO c FROM public.contracts k WHERE k.organization_id = v_org AND k.id = p_contract_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    -- The amount is money as text (the API never turns money into a float).
    IF p_amount_text IS NOT NULL THEN
        IF p_amount_text !~ '^\d{1,16}(\.\d{1,2})?$' OR p_amount_text::numeric <= 0 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: amount' USING ERRCODE = 'P0001';
        END IF;
        p_amount := p_amount_text::numeric;
    END IF;
    v_due := app.contract_due(v_org, c.id);
    v_remaining := (v_due -> 'due' ->> 'remaining')::numeric;
    IF p_amount IS NOT NULL THEN
        IF p_amount > v_remaining THEN
            v_alloc := jsonb_build_object('lines', '[]'::jsonb, 'completes_contract', false, 'exceeds_remaining', true);
        ELSE
            SELECT jsonb_build_object('lines', COALESCE(jsonb_agg(jsonb_build_object(
                       'seq', a.seq, 'due_date', a.due_date, 'profit', a.profit::text, 'principal', a.principal::text,
                       'amount', a.amount::text, 'pays_off', a.pays_off) ORDER BY a.seq), '[]'::jsonb),
                   'completes_contract', p_amount = v_remaining, 'exceeds_remaining', false)
            INTO v_alloc FROM app.collection_allocation(v_org, c.id, p_amount) a;
        END IF;
    END IF;
    RETURN jsonb_build_object(
        'contract', (SELECT jsonb_build_object('id', c.id, 'number', c.number, 'status', c.status,
                         'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1]),
                         'branch_id', c.branch_id, 'total_payable', c.total_payable::text)
                     FROM public.customers cu WHERE cu.id = c.customer_id AND cu.organization_id = v_org),
        'due', v_due -> 'due', 'lines', v_due -> 'lines', 'allocation', v_alloc);
END;
$$;

-- Contracts of the shop, newest first (decision 13). Filters (strict): q, customer_id, status
-- (one status or 'all'; default active + rescheduled), branch_id, overdue, limit (1-100, 25),
-- cursor (from the previous page).
CREATE FUNCTION public.list_contracts(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_q text; v_like text;
    v_customer uuid; v_branch uuid; v_status text; v_overdue boolean; v_limit integer := 25;
    v_cur_at timestamptz; v_cur_id uuid; v_all boolean; v_items jsonb; v_next text;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('q', 'customer_id', 'status', 'branch_id', 'overdue', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_q := NULLIF(btrim(f ->> 'q'), '');
        v_customer := (f ->> 'customer_id')::uuid;
        v_branch := (f ->> 'branch_id')::uuid;
        v_status := COALESCE(f ->> 'status', 'open');
        v_overdue := COALESCE((f ->> 'overdue')::boolean, false);
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_at := split_part(f ->> 'cursor', '|', 1)::timestamptz;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR length(v_q) > 100
       OR v_status NOT IN ('open', 'all', 'active', 'completed', 'rescheduled', 'written_off', 'returned') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
    v_all := app.has_permission('collection.create') OR app.has_permission('collection.reverse');

    WITH rows AS (
        SELECT c.id, c.number, c.status, c.branch_id, c.created_at, c.total_payable,
               cu.id AS cu_id, cu.full_name, cu.phones[1] AS phone,
               cb.paid, cb.remaining, cb.overdue_amount, cb.max_days_late, cb.next_due_date
        FROM public.contracts c
        JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
        JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
        WHERE c.organization_id = v_org
          AND (v_all OR app.has_branch_access(c.branch_id))
          AND (v_customer IS NULL OR c.customer_id = v_customer)
          AND (v_branch IS NULL OR c.branch_id = v_branch)
          AND (v_status = 'all' OR (v_status = 'open' AND c.status IN ('active', 'rescheduled'))
               OR c.status::text = v_status)
          AND (NOT v_overdue OR cb.overdue_amount > 0)
          AND (v_q IS NULL OR c.number ILIKE v_like || '%' OR cu.full_name ILIKE '%' || v_like || '%'
               OR EXISTS (SELECT 1 FROM unnest(cu.phones) ph WHERE ph ILIKE '%' || v_like || '%')
               OR cu.national_id = v_q)
          AND (v_cur_at IS NULL OR (c.created_at, c.id) < (v_cur_at, v_cur_id))
        ORDER BY c.created_at DESC, c.id DESC
        LIMIT v_limit + 1
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', r.id, 'number', r.number, 'status', r.status,
               'customer', jsonb_build_object('id', r.cu_id, 'name', r.full_name, 'phone', r.phone),
               'branch_id', r.branch_id, 'total_payable', r.total_payable::text, 'paid', r.paid::text,
               'remaining', r.remaining::text, 'overdue_amount', r.overdue_amount::text,
               'max_days_late', r.max_days_late, 'next_due_date', r.next_due_date)
               ORDER BY r.created_at DESC, r.id DESC) FILTER (WHERE r.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN r.n = v_limit THEN r.created_at::text || '|' || r.id::text END) END
    INTO v_items, v_next
    FROM (SELECT rows.*, row_number() OVER (ORDER BY created_at DESC, id DESC) AS n FROM rows) r;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next);
END;
$$;

-- A collection receipt (decision 14). The collection keys see every branch's.
CREATE FUNCTION public.get_collection(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_receipt public.payments;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('collection.create') OR app.has_permission('collection.reverse')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: collection.create' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    v_receipt := app.collection_receipt(v_org, p_id);
    IF v_receipt.id IS NULL THEN
        RAISE EXCEPTION 'COLLECTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.collection_json(v_org, v_receipt.id);
END;
$$;

-- A printed receipt is logged (S04's pattern): the first print is the original, later ones copies.
CREATE FUNCTION public.record_collection_receipt_print(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_receipt public.payments; n integer;
BEGIN
    IF app.has_permission('collection.create') THEN PERFORM app.require_permission('collection.create');
    ELSE PERFORM app.require_permission('collection.reverse'); END IF;
    PERFORM app.require_module('installments');
    v_org := app.current_org_id();
    v_receipt := app.collection_receipt(v_org, p_id);
    IF v_receipt.id IS NULL THEN
        RAISE EXCEPTION 'COLLECTION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    -- The receipt row's lock gives two tills printing the same receipt two different numbers.
    PERFORM 1 FROM public.payments p WHERE p.id = v_receipt.id FOR UPDATE;
    SELECT count(*) + 1 INTO n FROM public.audit_log a
    WHERE a.organization_id = v_org AND a.entity_type = 'payment' AND a.entity_id = v_receipt.id
      AND a.action = 'collection.receipt_printed';
    PERFORM app.write_audit('collection.receipt_printed', 'payment', v_receipt.id,
        p_after => jsonb_build_object('number', v_receipt.number, 'print_no', n, 'copy', n > 1),
        p_branch_id => v_receipt.branch_id);
    RETURN app.collection_json(v_org, v_receipt.id) || jsonb_build_object('print', jsonb_build_object('print_no', n, 'copy', n > 1));
END;
$$;

-- N02's contract read, with the visibility rule of decision 13 (its other checks unchanged).
CREATE OR REPLACE FUNCTION public.get_contract(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    SELECT c.branch_id INTO v_branch FROM public.contracts c WHERE c.organization_id = v_org AND c.id = p_id;
    IF NOT FOUND OR NOT app.can_see_contract(v_branch) THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.contract_json(v_org, p_id);
END;
$$;

REVOKE ALL ON FUNCTION public.post_collection(jsonb, text), public.reverse_collection(uuid, jsonb, text),
    public.preview_collection(uuid, text), public.list_contracts(jsonb), public.get_collection(uuid),
    public.record_collection_receipt_print(uuid), public.get_contract(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_collection(jsonb, text), public.reverse_collection(uuid, jsonb, text),
    public.preview_collection(uuid, text), public.list_contracts(jsonb), public.get_collection(uuid),
    public.record_collection_receipt_print(uuid), public.get_contract(uuid)
    TO authenticated;
