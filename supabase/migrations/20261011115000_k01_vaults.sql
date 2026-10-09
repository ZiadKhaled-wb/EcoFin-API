-- =============================================================================
-- K01 · Vaults (EC-59, D56)
--
-- Safes (one branch each) and bank accounts (one branch or shop-wide) the owner and the
-- accountant manage: create, rename, deactivate / reactivate, one opening balance, transfers
-- between them and the ledger of each with a running balance. Drawers (K02) and collector
-- wallets (N06) are not managed or listed here. Tables are in the baseline (cash_accounts,
-- cash_movements, cash_transfers, cash_balances); no table, column or enum changes.
--
-- Transfers (cash.transfer, access to the source account's branch; a shop-wide bank: anyone
-- with the key): numbered CX in the source's branch, one transfer_out and one transfer_in
-- movement in one transaction, accounts locked in id order. The ledger trigger refuses a safe
-- below 0 (INSUFFICIENT_FUNDS) and a closed day (DAY_CLOSED). Opening balance (cash.adjust):
-- once, on an account with no movements, through an import_jobs row (kind opening_cash, the I04
-- pattern). Both writes are idempotent by key. Reads (cash.view; also in an expired shop): the
-- safes and banks of the caller's branches plus every shop-wide bank (OWNER: all).
-- Numbered after the newest migration on main (D39): U06 is 20261011110000.
-- =============================================================================

-- 1. Helpers (not granted) ---------------------------------------------------------------------------

CREATE FUNCTION app.cash_account_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'name', a.name, 'kind', a.kind, 'branch_id', a.branch_id, 'branch_name', b.name,
        'is_active', a.is_active, 'archived_at', a.archived_at,
        'balance', COALESCE(cb.balance, 0)::numeric(18,2)::text,
        'is_default', EXISTS (SELECT 1 FROM public.branches d
                              WHERE d.organization_id = p_org AND d.default_cash_account_id = a.id),
        'created_at', a.created_at, 'updated_at', a.updated_at)
    FROM public.cash_accounts a
    LEFT JOIN public.branches b ON b.id = a.branch_id AND b.organization_id = a.organization_id
    LEFT JOIN public.cash_balances cb ON cb.cash_account_id = a.id
    WHERE a.organization_id = p_org AND a.id = p_id
$$;

-- A safe or bank of the caller's shop that the caller may see (decision 7).
CREATE FUNCTION app.cash_account_visible(p_account public.cash_accounts)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT p_account.kind IN ('safe', 'bank')
       AND (p_account.branch_id IS NULL OR app.has_branch_access(p_account.branch_id))
$$;

-- Loads an account for a read: the caller's shop, a safe or bank, visible; else not found.
CREATE FUNCTION app.cash_account_for_read(p_org uuid, p_id uuid)
RETURNS public.cash_accounts LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_a public.cash_accounts;
BEGIN
    SELECT * INTO v_a FROM public.cash_accounts a WHERE a.id = p_id AND a.organization_id = p_org;
    IF NOT FOUND OR NOT app.cash_account_visible(v_a) THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a;
END;
$$;

-- Loads and locks an account for a write: the caller's shop, a safe or bank; else not found.
CREATE FUNCTION app.cash_account_for_write(p_org uuid, p_id uuid)
RETURNS public.cash_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_a public.cash_accounts;
BEGIN
    SELECT * INTO v_a FROM public.cash_accounts a WHERE a.id = p_id AND a.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR v_a.kind NOT IN ('safe', 'bank') THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a;
END;
$$;

-- The caller may act on the account: its branch (active, accessible); a shop-wide bank: anyone.
CREATE FUNCTION app.require_cash_account_access(p_account public.cash_accounts)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_account.branch_id IS NOT NULL THEN
        PERFORM app.require_branch_access(p_account.branch_id);
    END IF;
END;
$$;

-- The branch a shop-wide bank's movement is booked in: the caller's default branch, else the main one.
CREATE FUNCTION app.cash_fallback_branch(p_org uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(
        (SELECT e.default_branch_id FROM public.employees e
         WHERE e.id = app.current_employee_id() AND e.organization_id = p_org),
        (SELECT b.id FROM public.branches b WHERE b.organization_id = p_org AND b.is_main LIMIT 1))
$$;

CREATE FUNCTION app.cash_amount(p_amount text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    IF p_amount IS NULL OR p_amount !~ '^\d{1,16}(\.\d{1,2})?$' OR p_amount::numeric(18,2) <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: amount' USING ERRCODE = 'P0001';
    END IF;
    RETURN p_amount::numeric(18,2);
END;
$$;

CREATE FUNCTION app.cash_account_name(p_name text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := btrim(p_name);
BEGIN
    IF v IS NULL OR length(v) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: name' USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

CREATE FUNCTION app.cash_transfer_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', t.id, 'number', t.number,
        'from_account_id', t.from_account_id, 'from_account_name', fa.name,
        'to_account_id', t.to_account_id, 'to_account_name', ta.name,
        'amount', t.amount::text, 'note', t.reason, 'business_date', t.business_date,
        'created_by_name', e.full_name, 'created_at', t.created_at)
    FROM public.cash_transfers t
    JOIN public.cash_accounts fa ON fa.id = t.from_account_id AND fa.organization_id = t.organization_id
    JOIN public.cash_accounts ta ON ta.id = t.to_account_id AND ta.organization_id = t.organization_id
    LEFT JOIN public.employees e ON e.id = t.created_by AND e.organization_id = t.organization_id
    WHERE t.organization_id = p_org AND t.id = p_id
$$;

CREATE FUNCTION app.require_cash_view()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('cash.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: cash.view' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- 2. Account writes ----------------------------------------------------------------------------------

-- A safe needs a branch; a bank may be shop-wide (p_branch_id NULL). Kind and branch are fixed.
CREATE FUNCTION public.create_cash_account(p_name text, p_kind text, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_name text; v_id uuid; v_json jsonb;
BEGIN
    v_emp := app.require_permission('cash.account_manage');
    v_org := app.current_org_id();
    v_name := app.cash_account_name(p_name);
    IF p_kind IS NULL OR p_kind NOT IN ('safe', 'bank') OR (p_kind = 'safe' AND p_branch_id IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: kind' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_branch_access(p_branch_id);
    END IF;
    BEGIN
        INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind, created_by, updated_by)
        VALUES (v_org, p_branch_id, v_name, p_kind::public.cash_account_kind, v_emp, v_emp)
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NAME_TAKEN' USING ERRCODE = 'P0001';
    END;
    v_json := app.cash_account_json(v_org, v_id);
    PERFORM app.write_audit('cash_account.created', 'cash_account', v_id, NULL, v_json - 'balance' - 'is_default',
        NULL, p_branch_id);
    RETURN v_json;
END;
$$;

-- Same name again: no change, no audit row. An inactive account can be renamed too.
CREATE FUNCTION public.rename_cash_account(p_id uuid, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.cash_accounts; v_name text;
BEGIN
    v_emp := app.require_permission('cash.account_manage');
    v_org := app.current_org_id();
    v_name := app.cash_account_name(p_name);
    v_a := app.cash_account_for_write(v_org, p_id);
    PERFORM app.require_cash_account_access(v_a);
    IF v_a.name = v_name THEN
        RETURN app.cash_account_json(v_org, p_id);
    END IF;
    BEGIN
        UPDATE public.cash_accounts a SET name = v_name, updated_by = v_emp, updated_at = now() WHERE a.id = p_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NAME_TAKEN' USING ERRCODE = 'P0001';
    END;
    PERFORM app.write_audit('cash_account.renamed', 'cash_account', p_id,
        jsonb_build_object('name', v_a.name), jsonb_build_object('name', v_name), NULL, v_a.branch_id);
    RETURN app.cash_account_json(v_org, p_id);
END;
$$;

-- Deactivate: refused with a balance or as a branch's default vault. Same state again: no change.
CREATE FUNCTION public.set_cash_account_active(p_id uuid, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.cash_accounts;
BEGIN
    v_emp := app.require_permission('cash.account_manage');
    v_org := app.current_org_id();
    IF p_active IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: active' USING ERRCODE = 'P0001';
    END IF;
    v_a := app.cash_account_for_write(v_org, p_id);
    PERFORM app.require_cash_account_access(v_a);
    IF v_a.is_active = p_active THEN
        RETURN app.cash_account_json(v_org, p_id);
    END IF;
    IF NOT p_active THEN
        IF COALESCE((SELECT cb.balance FROM public.cash_balances cb WHERE cb.cash_account_id = p_id), 0) <> 0 THEN
            RAISE EXCEPTION 'CASH_ACCOUNT_HAS_BALANCE' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.branches b
                   WHERE b.organization_id = v_org AND b.default_cash_account_id = p_id) THEN
            RAISE EXCEPTION 'CASH_ACCOUNT_IS_DEFAULT' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    BEGIN
        UPDATE public.cash_accounts a
           SET is_active = p_active, archived_at = CASE WHEN p_active THEN NULL ELSE now() END,
               updated_by = v_emp, updated_at = now()
         WHERE a.id = p_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_NAME_TAKEN' USING ERRCODE = 'P0001';
    END;
    PERFORM app.write_audit(CASE WHEN p_active THEN 'cash_account.reactivated' ELSE 'cash_account.deactivated' END,
        'cash_account', p_id, jsonb_build_object('is_active', v_a.is_active), jsonb_build_object('is_active', p_active),
        NULL, v_a.branch_id,
        CASE WHEN p_active THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN app.cash_account_json(v_org, p_id);
END;
$$;

-- 3. Money writes ------------------------------------------------------------------------------------

-- One opening balance on an account with no movements (decision 6). Idempotent by key.
CREATE FUNCTION public.post_cash_opening(p_id uuid, p_amount text, p_note text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.cash_accounts; v_amount numeric(18,2); v_note text; v_job uuid;
        v_done uuid;
BEGIN
    v_emp := app.require_permission('cash.adjust');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT (j.report ->> 'cash_account_id')::uuid INTO v_done FROM public.import_jobs j
    WHERE j.organization_id = v_org AND j.report ->> 'idempotency_key' = p_idempotency_key;
    IF FOUND THEN
        IF v_done IS DISTINCT FROM p_id THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: the idempotency key was used for another document' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.cash_account_json(v_org, p_id);        -- a repeat changes nothing
    END IF;

    v_amount := app.cash_amount(p_amount);
    v_note := btrim(p_note);
    IF v_note IS NULL OR length(v_note) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    v_a := app.cash_account_for_write(v_org, p_id);
    PERFORM app.require_cash_account_access(v_a);
    IF NOT v_a.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cash_movements m WHERE m.organization_id = v_org AND m.cash_account_id = p_id) THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_HAS_MOVEMENTS' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.import_jobs (organization_id, kind, status, dry_run, rows_total, rows_ok, report, created_by, finished_at)
    VALUES (v_org, 'opening_cash', 'completed', false, 1, 1,
            jsonb_build_object('kind', 'cash_opening', 'cash_account_id', p_id, 'amount', v_amount::text,
                               'note', v_note, 'idempotency_key', p_idempotency_key),
            v_emp, now())
    RETURNING id INTO v_job;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                       source_id, note, business_date, created_by, created_at)
    VALUES (v_org, p_id, COALESCE(v_a.branch_id, app.cash_fallback_branch(v_org)), v_amount, 'opening', 'import',
            v_job, v_note, app.org_today(v_org), v_emp, clock_timestamp());

    PERFORM app.write_audit('cash_account.opening_balance', 'cash_account', p_id, NULL,
        jsonb_build_object('amount', v_amount::text, 'import_job_id', v_job), v_note, v_a.branch_id);
    RETURN app.cash_account_json(v_org, p_id);
END;
$$;

CREATE FUNCTION public.create_cash_transfer(p_from uuid, p_to uuid, p_amount text, p_note text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_from public.cash_accounts; v_to public.cash_accounts; v_amount numeric(18,2);
    v_note text; v_id uuid; v_number text; v_date date; v_from_branch uuid; v_to_branch uuid;
BEGIN
    v_emp := app.require_permission('cash.transfer');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT t.id INTO v_id FROM public.cash_transfers t
    WHERE t.organization_id = v_org AND t.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.cash_transfer_json(v_org, v_id);       -- a repeat changes nothing
    END IF;

    v_amount := app.cash_amount(p_amount);
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: accounts' USING ERRCODE = 'P0001';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'TRANSFER_SAME_ACCOUNT' USING ERRCODE = 'P0001';
    END IF;
    -- Both accounts locked in id order: two transfers between the same pair can't deadlock.
    IF p_from < p_to THEN
        v_from := app.cash_account_for_write(v_org, p_from);
        v_to := app.cash_account_for_write(v_org, p_to);
    ELSE
        v_to := app.cash_account_for_write(v_org, p_to);
        v_from := app.cash_account_for_write(v_org, p_from);
    END IF;
    PERFORM app.require_cash_account_access(v_from);
    IF NOT v_from.is_active OR NOT v_to.is_active THEN
        RAISE EXCEPTION 'CASH_ACCOUNT_INACTIVE' USING ERRCODE = 'P0001';
    END IF;

    -- A shop-wide bank books in the other side's branch; both shop-wide: the caller's default branch.
    v_from_branch := COALESCE(v_from.branch_id, v_to.branch_id, app.cash_fallback_branch(v_org));
    v_to_branch := COALESCE(v_to.branch_id, v_from.branch_id, app.cash_fallback_branch(v_org));
    v_date := app.org_today(v_org);
    v_number := app.next_document_number(v_org, v_from_branch, 'cash_transfer');

    INSERT INTO public.cash_transfers (organization_id, number, from_account_id, to_account_id, amount, kind,
                                       reason, business_date, idempotency_key, created_by, created_at)
    VALUES (v_org, v_number, p_from, p_to, v_amount, 'transfer', v_note, v_date, p_idempotency_key, v_emp, clock_timestamp())
    RETURNING id INTO v_id;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, amount, type, source_type,
                                       source_id, note, business_date, created_by, created_at)
    VALUES (v_org, p_from, v_from_branch, -v_amount, 'transfer_out', 'cash_transfer', v_id, v_note, v_date, v_emp, clock_timestamp()),
           (v_org, p_to, v_to_branch, v_amount, 'transfer_in', 'cash_transfer', v_id, v_note, v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('cash_transfer.created', 'cash_transfer', v_id, NULL,
        jsonb_build_object('number', v_number, 'from_account_id', p_from, 'to_account_id', p_to,
                           'amount', v_amount::text),
        v_note, v_from_branch);
    RETURN app.cash_transfer_json(v_org, v_id);
END;
$$;

-- 4. Reads -------------------------------------------------------------------------------------------

-- p_status: active (default), inactive or all; p_branch_id: that branch's accounts only.
CREATE FUNCTION public.list_cash_accounts(p_status text DEFAULT 'active', p_branch_id uuid DEFAULT NULL,
                                          p_kind text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_cash_view();
    v_org := app.current_org_id();
    IF COALESCE(p_status, '') NOT IN ('active', 'inactive', 'all')
       OR (p_kind IS NOT NULL AND p_kind NOT IN ('safe', 'bank')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(app.cash_account_json(v_org, a.id)
                         ORDER BY (a.branch_id IS NULL), b.name, a.kind, a.name, a.id)
        FROM public.cash_accounts a
        LEFT JOIN public.branches b ON b.id = a.branch_id AND b.organization_id = a.organization_id
        WHERE a.organization_id = v_org AND app.cash_account_visible(a)
          AND (p_status = 'all' OR a.is_active = (p_status = 'active'))
          AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
          AND (p_kind IS NULL OR a.kind::text = p_kind)), '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.get_cash_account(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_cash_view();
    v_org := app.current_org_id();
    PERFORM app.cash_account_for_read(v_org, p_id);
    RETURN app.cash_account_json(v_org, p_id);
END;
$$;

-- The account's ledger, newest first. balance_after runs over the whole ledger (business date,
-- then creation time, then id); opening = the sum before p_from, closing = the sum up to p_to.
CREATE FUNCTION public.list_cash_account_movements(p_id uuid, p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                                   p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_result jsonb;
BEGIN
    PERFORM app.require_cash_view();
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.cash_account_for_read(v_org, p_id);

    WITH ledger AS (
        SELECT m.*, sum(m.amount) OVER (ORDER BY m.business_date, m.created_at, m.id) AS balance_after
        FROM public.cash_movements m
        WHERE m.organization_id = v_org AND m.cash_account_id = p_id
    ), shown AS (
        SELECT * FROM ledger l
        WHERE (p_from IS NULL OR l.business_date >= p_from) AND (p_to IS NULL OR l.business_date <= p_to)
    )
    SELECT jsonb_build_object(
        'account', app.cash_account_json(v_org, p_id),
        'from', p_from, 'to', p_to,
        'opening_balance', COALESCE((SELECT sum(l.amount) FROM ledger l
                                     WHERE p_from IS NOT NULL AND l.business_date < p_from), 0)::numeric(18,2)::text,
        'closing_balance', COALESCE((SELECT sum(l.amount) FROM ledger l
                                     WHERE p_to IS NULL OR l.business_date <= p_to), 0)::numeric(18,2)::text,
        'items', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', s.id, 'business_date', s.business_date, 'created_at', s.created_at, 'type', s.type,
                'amount', s.amount::text, 'balance_after', s.balance_after::numeric(18,2)::text,
                'source_type', s.source_type, 'source_id', s.source_id,
                'source_number', CASE s.source_type WHEN 'cash_transfer' THEN
                    (SELECT t.number FROM public.cash_transfers t
                     WHERE t.id = s.source_id AND t.organization_id = v_org) END,
                'note', s.note, 'created_by_name', e.full_name)
                ORDER BY s.business_date DESC, s.created_at DESC, s.id DESC)
            FROM (SELECT * FROM shown ORDER BY business_date DESC, created_at DESC, id DESC
                  LIMIT p_limit OFFSET p_offset) s
            LEFT JOIN public.employees e ON e.id = s.created_by AND e.organization_id = v_org), '[]'::jsonb),
        'total', (SELECT count(*) FROM shown))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Transfers with at least one side the caller may see, newest first; p_account_id: that account's.
CREATE FUNCTION public.list_cash_transfers(p_account_id uuid DEFAULT NULL, p_from date DEFAULT NULL,
                                           p_to date DEFAULT NULL, p_limit integer DEFAULT 50,
                                           p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_result jsonb;
BEGIN
    PERFORM app.require_cash_view();
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_account_id IS NOT NULL THEN
        PERFORM app.cash_account_for_read(v_org, p_account_id);
    END IF;

    WITH found AS (
        SELECT t.id, t.created_at FROM public.cash_transfers t
        JOIN public.cash_accounts fa ON fa.id = t.from_account_id AND fa.organization_id = t.organization_id
        JOIN public.cash_accounts ta ON ta.id = t.to_account_id AND ta.organization_id = t.organization_id
        WHERE t.organization_id = v_org AND t.kind = 'transfer'
          AND (app.cash_account_visible(fa) OR app.cash_account_visible(ta))
          AND (p_account_id IS NULL OR p_account_id IN (t.from_account_id, t.to_account_id))
          AND (p_from IS NULL OR t.business_date >= p_from) AND (p_to IS NULL OR t.business_date <= p_to)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.cash_transfer_json(v_org, f.id) ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_cash_transfer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_cash_view();
    v_org := app.current_org_id();
    IF NOT EXISTS (
        SELECT 1 FROM public.cash_transfers t
        JOIN public.cash_accounts fa ON fa.id = t.from_account_id AND fa.organization_id = t.organization_id
        JOIN public.cash_accounts ta ON ta.id = t.to_account_id AND ta.organization_id = t.organization_id
        WHERE t.id = p_id AND t.organization_id = v_org AND t.kind = 'transfer'
          AND (app.cash_account_visible(fa) OR app.cash_account_visible(ta))) THEN
        RAISE EXCEPTION 'CASH_TRANSFER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.cash_transfer_json(v_org, p_id);
END;
$$;

-- 5. Grants ------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.cash_account_json(uuid, uuid), app.cash_account_visible(public.cash_accounts),
    app.cash_account_for_read(uuid, uuid), app.cash_account_for_write(uuid, uuid),
    app.require_cash_account_access(public.cash_accounts), app.cash_fallback_branch(uuid),
    app.cash_amount(text), app.cash_account_name(text), app.cash_transfer_json(uuid, uuid),
    app.require_cash_view()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_cash_account(text, text, uuid), public.rename_cash_account(uuid, text),
    public.set_cash_account_active(uuid, boolean), public.post_cash_opening(uuid, text, text, text),
    public.create_cash_transfer(uuid, uuid, text, text, text), public.list_cash_accounts(text, uuid, text),
    public.get_cash_account(uuid), public.list_cash_account_movements(uuid, date, date, integer, integer),
    public.list_cash_transfers(uuid, date, date, integer, integer), public.get_cash_transfer(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_cash_account(text, text, uuid), public.rename_cash_account(uuid, text),
    public.set_cash_account_active(uuid, boolean), public.post_cash_opening(uuid, text, text, text),
    public.create_cash_transfer(uuid, uuid, text, text, text), public.list_cash_accounts(text, uuid, text),
    public.get_cash_account(uuid), public.list_cash_account_movements(uuid, date, date, integer, integer),
    public.list_cash_transfers(uuid, date, date, integer, integer), public.get_cash_transfer(uuid)
    TO authenticated;
