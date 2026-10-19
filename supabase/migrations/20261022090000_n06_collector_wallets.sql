-- =============================================================================
-- N06 · Collector wallets (EC-85, D81)
--
-- A collector takes installment payments in the field. The cash goes into the collector's own
-- wallet (a cash account of kind collector_wallet, one per collector, created by the first field
-- collection) and stays there until a manager settles it into a safe, in one transaction, with any
-- shortage recorded. Nothing is deducted from anyone (owner decision 4) and there is NO collection
-- commission of any kind (owner decision 1: collectors are salaried).
--
-- Rules (docs/tasks/N06.md, D81):
--   1. customers.collector_id: one collector per customer (the only schema change). The collector
--      is an active employee holding collection.create (COLLECTOR_INVALID otherwise).
--   2. post_field_collection = N03's collection core with no shift and the collector's wallet as
--      the cash account. The assigned collector, or a collector.settle holder, may use it.
--   3. settle_collector_wallet moves `handed` from the wallet to a safe of the wallet's branch
--      (cash_transfers kind collector_settlement, transfer_out + transfer_in) and books a shortage
--      as an `adjustment` movement on the wallet. Partial settlement is allowed; a stale
--      expected_balance, self-settlement and more than the balance are refused.
--   4. reverse_collection (recreated) also reverses a field collection: the same day, the cash
--      still in the wallet (nothing was handed in after it).
--   5. list_overdue_contracts gains the collector_id filter; a collector sees only their own.
--   6. org_settings.collector_commission_pct is set to 0 everywhere and nothing reads it.
--
-- Numbers: contracts 0.51.0, 7 routes. No new enum value and no new permission key.
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

ALTER TABLE public.customers ADD COLUMN collector_id uuid;
ALTER TABLE public.customers ADD CONSTRAINT customers_collector_fk
    FOREIGN KEY (collector_id, organization_id) REFERENCES public.employees (id, organization_id);
CREATE INDEX customers_collector_idx ON public.customers (organization_id, collector_id)
    WHERE collector_id IS NOT NULL;

-- Owner decision 1: no commission. The setting stays (an older Web sends it) but is 0 and unread.
UPDATE public.org_settings SET collector_commission_pct = 0 WHERE collector_commission_pct <> 0;

-- 2. Helpers (schema app, no grants) -----------------------------------------------------------------

-- The collector's wallet, created on first use under their default branch (the main one without).
CREATE FUNCTION app.wallet_for(p_org uuid, p_employee uuid)
RETURNS public.cash_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_w public.cash_accounts; v_e public.employees; v_branch uuid; v_name text;
BEGIN
    SELECT * INTO v_w FROM public.cash_accounts a
    WHERE a.organization_id = p_org AND a.employee_id = p_employee AND a.kind = 'collector_wallet';
    IF FOUND THEN
        RETURN v_w;
    END IF;
    SELECT * INTO v_e FROM public.employees e WHERE e.id = p_employee AND e.organization_id = p_org;
    v_branch := COALESCE(v_e.default_branch_id,
                         (SELECT b.id FROM public.branches b WHERE b.organization_id = p_org AND b.is_main LIMIT 1));
    v_name := left('Wallet · ' || v_e.full_name, 100);
    IF EXISTS (SELECT 1 FROM public.cash_accounts a
               WHERE a.organization_id = p_org AND a.branch_id = v_branch AND a.name = v_name) THEN
        v_name := left(v_name, 90) || ' · ' || left(p_employee::text, 4);
    END IF;
    INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind, employee_id, created_by)
    VALUES (p_org, v_branch, v_name, 'collector_wallet', p_employee, p_employee)
    ON CONFLICT DO NOTHING;
    SELECT * INTO v_w FROM public.cash_accounts a
    WHERE a.organization_id = p_org AND a.employee_id = p_employee AND a.kind = 'collector_wallet';
    RETURN v_w;
END;
$$;

CREATE FUNCTION app.wallet_balance(p_org uuid, p_wallet uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE((SELECT cb.balance FROM public.cash_balances cb
                     WHERE cb.organization_id = p_org AND cb.cash_account_id = p_wallet), 0)
$$;

-- The oldest business date of the cash still in the wallet: the newest collections that add up to
-- the balance (a settlement hands in the oldest cash first), reversed ones left out.
CREATE FUNCTION app.wallet_oldest_unsettled(p_org uuid, p_wallet uuid, p_balance numeric)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT min(x.business_date) FROM (
        SELECT m.business_date,
               COALESCE(sum(m.amount) OVER (ORDER BY m.business_date DESC, m.created_at DESC, m.id DESC
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before
        FROM public.cash_movements m
        WHERE m.organization_id = p_org AND m.cash_account_id = p_wallet AND m.type = 'collection' AND m.amount > 0
          AND NOT EXISTS (SELECT 1 FROM public.cash_movements r WHERE r.reverses_movement_id = m.id)
    ) x
    WHERE p_balance > 0 AND x.before < p_balance
$$;

CREATE FUNCTION app.wallet_settlement_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', t.id, 'number', t.number, 'business_date', t.business_date,
        'wallet_id', t.from_account_id, 'wallet_name', fa.name,
        'collector', jsonb_build_object('id', ce.id, 'name', ce.full_name),
        'to_account_id', t.to_account_id, 'to_account_name', ta.name,
        'handed', t.amount::text, 'shortage', t.shortage_amount::text, 'reason', t.reason,
        'balance_after', app.wallet_balance(p_org, t.from_account_id)::numeric(18,2)::text,
        'created_by_name', e.full_name, 'created_at', t.created_at)
    FROM public.cash_transfers t
    JOIN public.cash_accounts fa ON fa.id = t.from_account_id AND fa.organization_id = t.organization_id
    JOIN public.cash_accounts ta ON ta.id = t.to_account_id AND ta.organization_id = t.organization_id
    LEFT JOIN public.employees ce ON ce.id = fa.employee_id AND ce.organization_id = t.organization_id
    LEFT JOIN public.employees e ON e.id = t.created_by AND e.organization_id = t.organization_id
    WHERE t.organization_id = p_org AND t.id = p_id AND t.kind = 'collector_settlement'
$$;

CREATE FUNCTION app.wallet_last_settlement(p_org uuid, p_wallet uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', t.id, 'number', t.number, 'business_date', t.business_date,
                              'handed', t.amount::text, 'shortage', t.shortage_amount::text,
                              'created_at', t.created_at)
    FROM public.cash_transfers t
    WHERE t.organization_id = p_org AND t.from_account_id = p_wallet AND t.kind = 'collector_settlement'
    ORDER BY t.created_at DESC, t.id DESC LIMIT 1
$$;

CREATE FUNCTION app.wallet_row_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'name', a.name, 'is_active', a.is_active,
        'collector', jsonb_build_object('id', e.id, 'name', e.full_name),
        'branch_id', a.branch_id, 'branch_name', b.name,
        'balance', app.wallet_balance(p_org, a.id)::numeric(18,2)::text,
        'oldest_unsettled_date', app.wallet_oldest_unsettled(p_org, a.id, app.wallet_balance(p_org, a.id)),
        'last_settlement', app.wallet_last_settlement(p_org, a.id))
    FROM public.cash_accounts a
    JOIN public.employees e ON e.id = a.employee_id AND e.organization_id = a.organization_id
    JOIN public.branches b ON b.id = a.branch_id AND b.organization_id = a.organization_id
    WHERE a.organization_id = p_org AND a.id = p_id AND a.kind = 'collector_wallet'
$$;

-- The wallet reads: a signed-in employee of a shop with the installments module. An expired shop
-- may still read.
CREATE FUNCTION app.wallet_read_guard()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_org_id() IS NULL OR app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('installments');
    RETURN app.current_org_id();
END;
$$;

-- A money text: digits with at most two decimals, 0 allowed when p_zero.
CREATE FUNCTION app.wallet_amount(p_value jsonb, p_zero boolean, p_name text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    IF jsonb_typeof(p_value) IS DISTINCT FROM 'string' OR (p_value #>> '{}') !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_name USING ERRCODE = 'P0001';
    END IF;
    IF (p_value #>> '{}')::numeric(18,2) < 0 OR (NOT p_zero AND (p_value #>> '{}')::numeric(18,2) = 0) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_name USING ERRCODE = 'P0001';
    END IF;
    RETURN (p_value #>> '{}')::numeric(18,2);
END;
$$;

REVOKE ALL ON FUNCTION app.wallet_for(uuid, uuid), app.wallet_balance(uuid, uuid),
    app.wallet_oldest_unsettled(uuid, uuid, numeric), app.wallet_settlement_json(uuid, uuid),
    app.wallet_last_settlement(uuid, uuid), app.wallet_row_json(uuid, uuid), app.wallet_read_guard(),
    app.wallet_amount(jsonb, boolean, text)
    FROM PUBLIC, anon, authenticated;

-- 3. The customer's collector (decision 3) -------------------------------------------------------------

-- app.customer_json (R01) with the collector.
CREATE OR REPLACE FUNCTION app.customer_json(p_org uuid, p_id uuid, p_pii boolean)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'full_name', c.full_name, 'phones', to_jsonb(c.phones),
        'national_id', CASE WHEN p_pii THEN c.national_id END,
        'national_id_masked', app.mask_national_id(c.national_id),
        'birth_date', c.birth_date, 'gender', c.gender,
        'governorate_code', (SELECT p.governorate_code FROM app.parse_national_id(c.national_id) p),
        'address', c.address, 'city', c.city, 'job', c.job, 'employer', c.employer,
        'monthly_income', c.monthly_income::numeric(18,2)::text,
        'is_business', c.is_business, 'tax_registration_no', c.tax_registration_no,
        'status', c.status, 'notes', c.notes,
        'id_photos_count', (SELECT count(*) FROM public.files f
                            WHERE f.organization_id = p_org AND f.entity_type = 'customer'
                              AND f.entity_id = c.id AND f.purpose = 'customer_id'),
        'collector', (SELECT jsonb_build_object('id', e.id, 'name', e.full_name)
                      FROM public.employees e WHERE e.id = c.collector_id AND e.organization_id = p_org),
        'created_at', c.created_at, 'updated_at', c.updated_at)
    FROM public.customers c
    WHERE c.id = p_id AND c.organization_id = p_org
$$;

CREATE FUNCTION public.set_customer_collector(p_customer_id uuid, p_employee_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; c public.customers; v_reason text := NULLIF(btrim(p_reason), '');
BEGIN
    v_emp := app.require_permission('customer.edit');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    IF v_reason IS NOT NULL AND length(v_reason) NOT BETWEEN 3 AND 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO c FROM public.customers k WHERE k.id = p_customer_id AND k.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_employee_id IS NOT NULL AND NOT app.employee_can(v_org, p_employee_id, 'collection.create') THEN
        RAISE EXCEPTION 'COLLECTOR_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('employee_id', p_employee_id)::text;
    END IF;
    IF c.collector_id IS NOT DISTINCT FROM p_employee_id THEN
        RETURN app.customer_json(v_org, c.id, app.has_permission('customer.view_pii'));   -- nothing changes
    END IF;
    UPDATE public.customers k SET collector_id = p_employee_id, updated_at = now(), updated_by = v_emp
    WHERE k.id = c.id;
    PERFORM app.write_audit('customer.collector_set', 'customer', c.id,
        jsonb_build_object('collector_id', c.collector_id), jsonb_build_object('collector_id', p_employee_id),
        v_reason);
    RETURN app.customer_json(v_org, c.id, app.has_permission('customer.view_pii'));
END;
$$;

-- 4. Field collection (decision 4) ---------------------------------------------------------------------

CREATE FUNCTION public.post_field_collection(p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_in jsonb; v_existing public.payments; v_wallet public.cash_accounts;
    v_customer public.customers; v_receipt uuid;
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
        IF v_existing.collection_id = v_existing.id AND v_existing.direction = 'in'
           AND v_existing.shift_id IS NULL AND v_existing.received_by = v_emp THEN
            RETURN app.collection_json(v_org, v_existing.id);    -- a repeat collects nothing
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another payment' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales s WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key) THEN
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by a sale' USING ERRCODE = 'P0001';
    END IF;

    v_in := app.collection_input(p_body);

    -- Owner decision 2: the customer's assigned collector, or a collector.settle holder.
    SELECT * INTO v_customer FROM public.customers c
    WHERE c.id = (v_in ->> 'customer_id')::uuid AND c.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_customer.collector_id IS DISTINCT FROM v_emp AND NOT app.has_permission('collector.settle') THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_ASSIGNED' USING ERRCODE = 'P0001';
    END IF;

    -- The caller's own wallet (owner decision 6: made by the first field collection).
    v_wallet := app.wallet_for(v_org, v_emp);
    IF NOT v_wallet.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_wallet.branch_id);

    v_receipt := app.post_collection_core(v_org, v_emp, v_wallet.branch_id, NULL, v_wallet.id, v_in, p_idempotency_key);
    RETURN app.collection_json(v_org, v_receipt);
END;
$$;

-- 5. Settlement (decision 6) -----------------------------------------------------------------------------

CREATE FUNCTION public.settle_collector_wallet(p_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_w public.cash_accounts; v_to public.cash_accounts; v_t uuid; v_number text;
    v_handed numeric; v_shortage numeric := 0; v_expected numeric; v_balance numeric; v_reason text;
    v_date date; v_to_id uuid; v_note text; v_first uuid;
BEGIN
    v_emp := app.require_permission('collector.settle');
    v_org := app.current_org_id();
    PERFORM app.require_module('installments');
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    IF p_idempotency_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency key' USING ERRCODE = 'P0001';
    END IF;

    SELECT t.id INTO v_t FROM public.cash_transfers t
    WHERE t.organization_id = v_org AND t.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF EXISTS (SELECT 1 FROM public.cash_transfers t
                   WHERE t.id = v_t AND t.kind = 'collector_settlement' AND t.from_account_id = p_id) THEN
            RETURN app.wallet_settlement_json(v_org, v_t);       -- a repeat settles nothing
        END IF;
        RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used by another transfer' USING ERRCODE = 'P0001';
    END IF;

    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) k
                  WHERE k NOT IN ('to_account_id', 'handed', 'shortage', 'reason', 'expected_balance')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        v_to_id := (p_body ->> 'to_account_id')::uuid;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: to_account_id' USING ERRCODE = 'P0001';
    END;
    IF v_to_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: to_account_id' USING ERRCODE = 'P0001';
    END IF;
    v_handed := app.wallet_amount(p_body -> 'handed', false, 'handed');
    v_expected := app.wallet_amount(p_body -> 'expected_balance', true, 'expected_balance');
    IF p_body ? 'shortage' AND jsonb_typeof(p_body -> 'shortage') <> 'null' THEN
        v_shortage := app.wallet_amount(p_body -> 'shortage', true, 'shortage');
    END IF;
    IF p_body ? 'reason' AND jsonb_typeof(p_body -> 'reason') <> 'null' THEN
        IF jsonb_typeof(p_body -> 'reason') <> 'string' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
        END IF;
        v_reason := NULLIF(btrim(p_body ->> 'reason'), '');
    END IF;
    IF (v_shortage > 0 AND (v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 300))
       OR length(v_reason) > 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_w FROM public.cash_accounts a
    WHERE a.id = p_id AND a.organization_id = v_org AND a.kind = 'collector_wallet';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WALLET_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_w.employee_id = v_emp THEN
        RAISE EXCEPTION 'SELF_SETTLEMENT' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_w.branch_id);

    -- Both accounts locked in id order (K01): two settlements into one safe can't deadlock.
    IF p_id < v_to_id THEN
        SELECT * INTO v_w FROM public.cash_accounts a WHERE a.id = p_id FOR UPDATE;
        SELECT * INTO v_to FROM public.cash_accounts a WHERE a.id = v_to_id AND a.organization_id = v_org FOR UPDATE;
    ELSE
        SELECT * INTO v_to FROM public.cash_accounts a WHERE a.id = v_to_id AND a.organization_id = v_org FOR UPDATE;
        SELECT * INTO v_w FROM public.cash_accounts a WHERE a.id = p_id FOR UPDATE;
    END IF;
    IF v_to.id IS NULL OR v_to.kind <> 'safe' OR v_to.branch_id IS DISTINCT FROM v_w.branch_id
       OR NOT v_to.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    v_balance := app.wallet_balance(v_org, v_w.id);
    IF v_balance <> v_expected THEN
        RAISE EXCEPTION 'WALLET_BALANCE_CHANGED: the wallet holds %', v_balance USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('balance', v_balance::numeric(18,2)::text)::text;
    END IF;
    IF v_handed + v_shortage > v_balance THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS: the wallet holds %', v_balance USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('balance', v_balance::numeric(18,2)::text)::text;
    END IF;

    v_date := app.org_today(v_org);
    v_number := app.next_document_number(v_org, v_w.branch_id, 'cash_transfer');
    v_note := left(concat_ws(' · ', 'Settlement ' || v_number, v_reason), 200);
    INSERT INTO public.cash_transfers (organization_id, number, from_account_id, to_account_id, amount, kind,
                                       shortage_amount, reason, business_date, idempotency_key, created_by, created_at)
    VALUES (v_org, v_number, v_w.id, v_to.id, v_handed, 'collector_settlement', v_shortage, v_reason, v_date,
            p_idempotency_key, v_emp, clock_timestamp())
    RETURNING id INTO v_t;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                       source_id, note, business_date, created_by, created_at)
    VALUES (v_org, v_w.id, v_w.branch_id, -v_handed, 'transfer_out', 'cash_transfer', v_t, v_note, v_date, v_emp,
            clock_timestamp()),
           (v_org, v_to.id, v_to.branch_id, v_handed, 'transfer_in', 'cash_transfer', v_t, v_note, v_date, v_emp,
            clock_timestamp());
    IF v_shortage > 0 THEN
        INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                           source_id, note, business_date, created_by, created_at)
        VALUES (v_org, v_w.id, v_w.branch_id, -v_shortage, 'adjustment', 'cash_transfer', v_t,
                left('Shortage · ' || v_number || ' · ' || v_reason, 200), v_date, v_emp, clock_timestamp());
    END IF;

    PERFORM app.write_audit('collector.wallet_settled', 'cash_transfer', v_t, NULL,
        jsonb_build_object('number', v_number, 'wallet_id', v_w.id, 'collector_id', v_w.employee_id,
                           'to_account_id', v_to.id, 'handed', v_handed::numeric(18,2)::text,
                           'shortage', v_shortage::numeric(18,2)::text,
                           'balance_before', v_balance::numeric(18,2)::text,
                           'balance_after', (v_balance - v_handed - v_shortage)::numeric(18,2)::text),
        v_reason, v_w.branch_id, CASE WHEN v_shortage > 0 THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.wallet_settlement_json(v_org, v_t);
END;
$$;

-- 6. Reads (decision 8) ---------------------------------------------------------------------------------

CREATE FUNCTION public.get_my_wallet()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_emp uuid; v_w public.cash_accounts; v_date date; v_bal numeric; v_today jsonb;
BEGIN
    v_org := app.wallet_read_guard();
    v_emp := app.current_employee_id();
    IF NOT app.has_permission('collection.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: collection.create' USING ERRCODE = '42501';
    END IF;
    v_date := app.org_today(v_org);
    SELECT jsonb_build_object(
        'count', count(*),
        'amount', COALESCE(sum((SELECT sum(x.amount) FROM public.payments x
                                WHERE x.organization_id = v_org AND x.collection_id = p.id)), 0)::numeric(18,2)::text,
        'cash', COALESCE(sum((SELECT sum(x.amount) FROM public.payments x
                              WHERE x.organization_id = v_org AND x.collection_id = p.id AND x.method = 'cash')), 0)::numeric(18,2)::text)
    INTO v_today
    FROM public.payments p
    WHERE p.organization_id = v_org AND p.collection_id = p.id AND p.direction = 'in' AND p.shift_id IS NULL
      AND p.received_by = v_emp AND p.business_date = v_date
      AND NOT EXISTS (SELECT 1 FROM public.payments r WHERE r.organization_id = v_org AND r.reverses_payment_id = p.id);
    SELECT * INTO v_w FROM public.cash_accounts a
    WHERE a.organization_id = v_org AND a.employee_id = v_emp AND a.kind = 'collector_wallet';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('wallet', NULL, 'balance', '0.00', 'today', v_today,
                                  'oldest_unsettled_date', NULL, 'last_settlement', NULL);
    END IF;
    v_bal := app.wallet_balance(v_org, v_w.id);
    RETURN jsonb_build_object(
        'wallet', jsonb_build_object('id', v_w.id, 'name', v_w.name, 'branch_id', v_w.branch_id,
                                     'branch_name', (SELECT b.name FROM public.branches b WHERE b.id = v_w.branch_id)),
        'balance', v_bal::numeric(18,2)::text, 'today', v_today,
        'oldest_unsettled_date', app.wallet_oldest_unsettled(v_org, v_w.id, v_bal),
        'last_settlement', app.wallet_last_settlement(v_org, v_w.id));
END;
$$;

CREATE FUNCTION public.list_collector_wallets(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_branch uuid; v_items jsonb;
BEGIN
    v_org := app.wallet_read_guard();
    IF NOT (app.has_permission('collector.settle') OR app.has_permission('cash.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: collector.settle' USING ERRCODE = '42501';
    END IF;
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key <> 'branch_id' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_branch := (f ->> 'branch_id')::uuid;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    SELECT COALESCE(jsonb_agg(app.wallet_row_json(v_org, a.id)
                              ORDER BY app.wallet_balance(v_org, a.id) DESC, a.name, a.id), '[]'::jsonb)
    INTO v_items
    FROM public.cash_accounts a
    WHERE a.organization_id = v_org AND a.kind = 'collector_wallet' AND a.is_active
      AND (v_branch IS NULL OR a.branch_id = v_branch) AND app.has_branch_access(a.branch_id);
    RETURN jsonb_build_object('items', v_items);
END;
$$;

CREATE FUNCTION public.list_wallet_movements(p_id uuid, p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_w public.cash_accounts;
    v_from date; v_to date; v_limit integer := 50; v_cur_at timestamptz; v_cur_id uuid;
    v_items jsonb; v_next text; v_own boolean;
BEGIN
    v_org := app.wallet_read_guard();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('from', 'to', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_from := (f ->> 'from')::date;
        v_to := (f ->> 'to')::date;
        v_limit := COALESCE((f ->> 'limit')::integer, 50);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_at := split_part(f ->> 'cursor', '|', 1)::timestamptz;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR (v_from IS NOT NULL AND v_to IS NOT NULL AND v_from > v_to) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_w FROM public.cash_accounts a
    WHERE a.id = p_id AND a.organization_id = v_org AND a.kind = 'collector_wallet';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WALLET_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_own := v_w.employee_id = app.current_employee_id() AND app.has_permission('collection.create');
    IF NOT v_own THEN
        IF NOT (app.has_permission('collector.settle') OR app.has_permission('cash.view')) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED: collector.settle' USING ERRCODE = '42501';
        END IF;
        IF NOT app.has_branch_access(v_w.branch_id) THEN
            RAISE EXCEPTION 'WALLET_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    WITH ledger AS (
        SELECT m.*, sum(m.amount) OVER (ORDER BY m.created_at, m.id) AS balance_after
        FROM public.cash_movements m
        WHERE m.organization_id = v_org AND m.cash_account_id = v_w.id
    ), shown AS (
        SELECT l.*, row_number() OVER (ORDER BY l.created_at DESC, l.id DESC) AS n
        FROM ledger l
        WHERE (v_from IS NULL OR l.business_date >= v_from) AND (v_to IS NULL OR l.business_date <= v_to)
          AND (v_cur_id IS NULL OR (l.created_at, l.id) < (v_cur_at, v_cur_id))
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', s.id, 'business_date', s.business_date, 'created_at', s.created_at, 'type', s.type,
               'amount', s.amount::text, 'balance_after', s.balance_after::numeric(18,2)::text,
               'source_type', s.source_type, 'source_id', s.source_id,
               'source_number', CASE s.source_type
                   WHEN 'cash_transfer' THEN (SELECT t.number FROM public.cash_transfers t
                                              WHERE t.id = s.source_id AND t.organization_id = v_org)
                   WHEN 'payment' THEN (SELECT p.number FROM public.payments p
                                        WHERE p.id = s.source_id AND p.organization_id = v_org) END,
               'note', s.note, 'created_by_name', e.full_name,
               'settlement', (SELECT jsonb_build_object('handed', t.amount::text, 'shortage', t.shortage_amount::text,
                                                        'reason', t.reason)
                              FROM public.cash_transfers t
                              WHERE s.source_type = 'cash_transfer' AND t.id = s.source_id
                                AND t.organization_id = v_org AND t.kind = 'collector_settlement'))
               ORDER BY s.created_at DESC, s.id DESC) FILTER (WHERE s.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN s.n = v_limit
                              THEN to_char(s.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || s.id::text END) END
    INTO v_items, v_next
    FROM shown s
    LEFT JOIN public.employees e ON e.id = s.created_by AND e.organization_id = v_org;
    RETURN jsonb_build_object('wallet', app.wallet_row_json(v_org, v_w.id), 'items', v_items, 'next_cursor', v_next);
END;
$$;

-- The route (decision 8): the collector's customers with something due or overdue on the date,
-- sorted by city, address, name. A line is overdue once its grace days are over on that date.
CREATE FUNCTION public.get_collector_route(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_target uuid; v_date date;
    v_stops jsonb; v_totals jsonb;
BEGIN
    v_org := app.wallet_read_guard();
    IF NOT app.has_permission('collection.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: collection.create' USING ERRCODE = '42501';
    END IF;
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('employee_id', 'date') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_target := COALESCE((f ->> 'employee_id')::uuid, app.current_employee_id());
        v_date := COALESCE((f ->> 'date')::date, app.org_today(v_org));
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_target <> app.current_employee_id() THEN
        IF NOT app.has_permission('collector.settle') THEN
            RAISE EXCEPTION 'PERMISSION_DENIED: collector.settle' USING ERRCODE = '42501';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = v_target AND e.organization_id = v_org) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    WITH lines AS (
        SELECT c.customer_id, c.id AS contract_id, c.number, ls.due_date, ls.remaining,
               (ls.due_date + ip.grace_days) < v_date AS late
        FROM public.customers cu
        JOIN public.contracts c ON c.customer_id = cu.id AND c.organization_id = cu.organization_id
        JOIN public.installment_policies ip ON ip.id = c.policy_id
        JOIN public.v_schedule_line_status ls ON ls.contract_id = c.id AND ls.organization_id = c.organization_id
        WHERE cu.organization_id = v_org AND cu.collector_id = v_target
          AND c.status IN ('active', 'rescheduled') AND NOT ls.superseded AND ls.remaining > 0
    ), per_contract AS (
        SELECT l.customer_id, l.contract_id, l.number,
               sum(l.remaining) FILTER (WHERE l.due_date <= v_date) AS amount_due,
               COALESCE(sum(l.remaining) FILTER (WHERE l.late), 0) AS amount_overdue,
               COALESCE(max(GREATEST(v_date - l.due_date, 0)) FILTER (WHERE l.due_date <= v_date), 0) AS days_late,
               min(l.due_date) FILTER (WHERE l.due_date > v_date) AS next_due_date
        FROM lines l GROUP BY l.customer_id, l.contract_id, l.number
    ), stops AS (
        SELECT cu.id, cu.full_name, cu.phones[1] AS phone, cu.address, cu.city,
               sum(pc.amount_due) AS amount_due, sum(pc.amount_overdue) AS amount_overdue,
               max(pc.days_late) AS max_days_late, min(pc.next_due_date) AS next_due_date,
               jsonb_agg(jsonb_build_object('id', pc.contract_id, 'number', pc.number,
                                            'amount_due', pc.amount_due::numeric(18,2)::text,
                                            'amount_overdue', pc.amount_overdue::numeric(18,2)::text)
                         ORDER BY pc.number) AS contracts
        FROM per_contract pc
        JOIN public.customers cu ON cu.id = pc.customer_id AND cu.organization_id = v_org
        WHERE pc.amount_due > 0
        GROUP BY cu.id, cu.full_name, cu.phones[1], cu.address, cu.city
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'customer', jsonb_build_object('id', s.id, 'name', s.full_name, 'phone', s.phone,
                                              'address', s.address, 'city', s.city),
               'amount_due', s.amount_due::numeric(18,2)::text, 'amount_overdue', s.amount_overdue::numeric(18,2)::text,
               'max_days_late', s.max_days_late, 'next_due_date', s.next_due_date, 'contracts', s.contracts)
               ORDER BY s.city NULLS LAST, s.address NULLS LAST, s.full_name, s.id), '[]'::jsonb),
           jsonb_build_object('customers', count(*),
                              'amount_due', COALESCE(sum(s.amount_due), 0)::numeric(18,2)::text,
                              'amount_overdue', COALESCE(sum(s.amount_overdue), 0)::numeric(18,2)::text)
    INTO v_stops, v_totals
    FROM stops s;
    RETURN jsonb_build_object('employee_id', v_target,
                              'employee_name', (SELECT e.full_name FROM public.employees e
                                                WHERE e.id = v_target AND e.organization_id = v_org),
                              'date', v_date, 'stops', v_stops, 'totals', v_totals);
END;
$$;

-- 7. The overdue list: the collector filter (decision 9; N04's function, three additions) --------------

CREATE OR REPLACE FUNCTION public.list_overdue_contracts(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_q text; v_like text;
    v_branch uuid; v_min integer; v_limit integer := 25; v_cur_days integer; v_cur_id uuid;
    v_items jsonb; v_next text; v_totals jsonb; v_collector uuid;
BEGIN
    v_org := app.overdue_read_guard();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('q', 'branch_id', 'min_days', 'limit', 'cursor', 'collector_id') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_q := NULLIF(btrim(f ->> 'q'), '');
        v_branch := (f ->> 'branch_id')::uuid;
        v_collector := (f ->> 'collector_id')::uuid;
        v_min := COALESCE((f ->> 'min_days')::integer, 1);
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_days := split_part(f ->> 'cursor', '|', 1)::integer;
            v_cur_id := split_part(f ->> 'cursor', '|', 2)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR v_min NOT BETWEEN 1 AND 100000 OR length(v_q) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    -- N06 (decision 9): a collector (collection.create, not collector.settle) sees only their own customers.
    IF app.has_permission('collection.create') AND NOT app.has_permission('collector.settle') THEN
        v_collector := app.current_employee_id();
    END IF;
    v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

    WITH base AS (
        SELECT c.id AS contract_id, c.number, c.frequency::text AS frequency, c.branch_id, cu.id AS customer_id, cu.collector_id,
               cu.full_name, cu.phones[1] AS phone, cu.status::text AS customer_status, cb.overdue_amount,
               cb.overdue_lines, cb.max_days_late, cb.remaining
        FROM public.contracts c
        JOIN public.customers cu ON cu.id = c.customer_id AND cu.organization_id = c.organization_id
        JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
        WHERE c.organization_id = v_org AND c.status IN ('active', 'rescheduled') AND cb.overdue_amount > 0
          AND cb.max_days_late >= v_min
          AND (v_branch IS NULL OR c.branch_id = v_branch)
          AND (v_collector IS NULL OR cu.collector_id = v_collector)
          AND (v_q IS NULL OR c.number ILIKE v_like || '%' OR cu.full_name ILIKE '%' || v_like || '%'
               OR EXISTS (SELECT 1 FROM unnest(cu.phones) ph WHERE ph ILIKE '%' || v_like || '%')
               OR cu.national_id = v_q)
    ), totals AS (
        SELECT jsonb_build_object(
            'contracts', count(DISTINCT b.contract_id),
            'overdue_amount', COALESCE(sum(ls.remaining), 0)::numeric(18,2)::text,
            'late_1_30',   COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 1 AND 30), 0)::numeric(18,2)::text,
            'late_31_60',  COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 31 AND 60), 0)::numeric(18,2)::text,
            'late_61_90',  COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late BETWEEN 61 AND 90), 0)::numeric(18,2)::text,
            'late_90_plus', COALESCE(sum(ls.remaining) FILTER (WHERE ls.days_late > 90), 0)::numeric(18,2)::text) AS t
        FROM base b
        JOIN public.v_schedule_line_status ls ON ls.contract_id = b.contract_id AND ls.status = 'overdue'
    ), page AS (
        SELECT b.*, row_number() OVER (ORDER BY b.max_days_late DESC, b.contract_id) AS n
        FROM base b
        WHERE v_cur_id IS NULL OR b.max_days_late < v_cur_days
              OR (b.max_days_late = v_cur_days AND b.contract_id > v_cur_id)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'contract', jsonb_build_object('id', p.contract_id, 'number', p.number,
                                              'frequency', p.frequency, 'branch_id', p.branch_id),
               'customer', jsonb_build_object('id', p.customer_id, 'name', p.full_name, 'phone', p.phone,
                                              'status', p.customer_status, 'collector_id', p.collector_id),
               'overdue_amount', p.overdue_amount::text, 'overdue_lines', p.overdue_lines,
               'max_days_late', p.max_days_late, 'remaining', p.remaining::text,
               'oldest_due_date', (SELECT min(ls.due_date) FROM public.v_schedule_line_status ls
                                   WHERE ls.contract_id = p.contract_id AND ls.status = 'overdue'),
               'last_payment_at', (SELECT max(ea.paid_at) FROM public.v_effective_allocations ea
                                   WHERE ea.contract_id = p.contract_id AND ea.direction = 'in'),
               'open_warning', (SELECT jsonb_build_object('id', a.id, 'business_date', a.business_date)
                                FROM public.overdue_actions a
                                WHERE a.contract_id = p.contract_id AND a.kind = 'warning' AND a.status = 'open'
                                ORDER BY a.business_date DESC LIMIT 1),
               'legal_referral', (SELECT jsonb_build_object('id', a.id, 'status', a.status,
                                                           'business_date', a.business_date)
                                  FROM public.overdue_actions a
                                  WHERE a.contract_id = p.contract_id AND a.kind = 'legal_referral'
                                    AND a.status IN ('open', 'case_opened')
                                  ORDER BY a.business_date DESC LIMIT 1))
               ORDER BY p.max_days_late DESC, p.contract_id) FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit THEN p.max_days_late::text || '|' || p.contract_id::text END) END,
           (SELECT t FROM totals)
    INTO v_items, v_next, v_totals
    FROM page p;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next, 'totals', v_totals);
END;
$$;

-- 8. Collections: field collections can be reversed (decision 5; N05's function, one block changed) ----

CREATE OR REPLACE FUNCTION public.reverse_collection(p_id uuid, p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_receipt public.payments; v_existing public.payments; v_shift public.shifts;
    v_reason text; v_date date; v_first uuid := gen_random_uuid(); v_rid uuid; v_n integer := 0;
    pay public.payments; cm public.cash_movements; c public.contracts; v_later uuid; v_status public.contract_status;
    v_contracts jsonb := '[]'::jsonb; v_reopened uuid[] := '{}'; i integer; w public.cash_accounts;
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
    IF v_receipt.shift_id IS NOT NULL THEN
        -- The money goes back out of the drawer that took it: that shift must still be open.
        SELECT * INTO v_shift FROM public.shifts s WHERE s.id = v_receipt.shift_id AND s.organization_id = v_org FOR UPDATE;
        IF v_shift.id IS NULL OR v_shift.status <> 'open' THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: the shift is closed' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'shift_closed')::text;
        END IF;
        PERFORM app.require_shift_device(v_shift.id);
    ELSE
        -- N06 (decision 5): a field collection. Its cash goes back out of the same wallet, which is
        -- refused once any of it was handed in after the collection (the ledger also refuses a wallet
        -- that no longer holds the cash).
        FOR w IN SELECT a.* FROM public.cash_accounts a
                 WHERE a.organization_id = v_org AND a.kind = 'collector_wallet'
                   AND a.id IN (SELECT m.cash_account_id FROM public.cash_movements m
                                WHERE m.organization_id = v_org AND m.source_type = 'payment' AND m.type = 'collection'
                                  AND m.source_id IN (SELECT p.id FROM public.payments p
                                                      WHERE p.organization_id = v_org AND p.collection_id = v_receipt.id))
                 ORDER BY a.id FOR UPDATE LOOP
            IF EXISTS (SELECT 1 FROM public.cash_transfers t
                       WHERE t.organization_id = v_org AND t.kind = 'collector_settlement'
                         AND t.from_account_id = w.id AND t.created_at > v_receipt.paid_at) THEN
                RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: already handed in' USING ERRCODE = 'P0001',
                    DETAIL = jsonb_build_object('reason', 'handed_in')::text;
            END IF;
        END LOOP;
    END IF;

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
        -- N05 (decision 8): a settlement's collection carries its waiver; a contract changed since
        -- the collection no longer carries the lines it paid.
        IF EXISTS (SELECT 1 FROM public.contract_changes x
                   WHERE x.organization_id = v_org AND x.contract_id = c.id AND x.payment_id = v_receipt.id) THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: an early settlement' USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'settlement', 'contract_id', c.id)::text;
        END IF;
        IF EXISTS (SELECT 1 FROM public.contract_changes x
                   WHERE x.organization_id = v_org AND x.contract_id = c.id AND x.created_at > v_receipt.paid_at) THEN
            RAISE EXCEPTION 'COLLECTION_NOT_REVERSIBLE: % changed since', c.number USING ERRCODE = 'P0001',
                DETAIL = jsonb_build_object('reason', 'contract_changed', 'contract_id', c.id)::text;
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

-- 9. Grants ----------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.set_customer_collector(uuid, uuid, text), public.post_field_collection(jsonb, text),
    public.settle_collector_wallet(uuid, jsonb, text), public.get_my_wallet(),
    public.list_collector_wallets(jsonb), public.list_wallet_movements(uuid, jsonb),
    public.get_collector_route(jsonb), public.list_overdue_contracts(jsonb), public.reverse_collection(uuid, jsonb, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_customer_collector(uuid, uuid, text), public.post_field_collection(jsonb, text),
    public.settle_collector_wallet(uuid, jsonb, text), public.get_my_wallet(),
    public.list_collector_wallets(jsonb), public.list_wallet_movements(uuid, jsonb),
    public.get_collector_route(jsonb), public.list_overdue_contracts(jsonb), public.reverse_collection(uuid, jsonb, text)
    TO authenticated;
