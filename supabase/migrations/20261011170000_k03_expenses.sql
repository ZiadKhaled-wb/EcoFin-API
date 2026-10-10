-- =============================================================================
-- K03 · Expenses (EC-61, D61)
--
-- Money the shop spends (rent, transport, salaries paid in cash): an amount, a category, where
-- the money leaves from, an optional note and receipt photo. The source is a vault (an active
-- safe or bank of the branch, or a shop-wide bank) or the caller's open shift (its drawer, so the
-- expense is part of the shift's expected cash). The money leaves through the cash ledger
-- (type expense, -amount): a safe or drawer can't go below 0 and a closed day is refused.
-- Numbered EX; idempotent by key. Never edited or deleted: the owner reverses an expense with a
-- reason (a linked EX row and the money back), once. Categories are a small list per shop.
-- Reads and the report by category: expense.create, cash.view or report.financial, the
-- caller's branches; also in an expired shop.
-- =============================================================================

-- 1. Helpers -------------------------------------------------------------------------------------------

CREATE FUNCTION app.expense_category_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', c.id, 'name', c.name, 'archived_at', c.archived_at,
                              'created_at', c.created_at, 'updated_at', c.updated_at)
    FROM public.expense_categories c WHERE c.organization_id = p_org AND c.id = p_id
$$;

-- Trimmed category name: 1-80 characters.
CREATE FUNCTION app.expense_category_name(p_name text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text := btrim(p_name);
BEGIN
    IF v IS NULL OR length(v) NOT BETWEEN 1 AND 80 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: name' USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

CREATE FUNCTION app.expense_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', x.id, 'number', x.number, 'branch_id', x.branch_id, 'category_id', x.category_id,
        'category_name', c.name, 'amount', x.amount::text, 'cash_account_id', x.cash_account_id,
        'cash_account_name', a.name, 'cash_account_kind', a.kind, 'shift_id', x.shift_id,
        'shift_number', s.number, 'note', x.note, 'receipt_file_id', x.receipt_file_id,
        'reverses_expense_id', x.reverses_expense_id,
        'reversed_by_expense_id', (SELECT r.id FROM public.expenses r
                                   WHERE r.organization_id = p_org AND r.reverses_expense_id = x.id),
        'business_date', x.business_date, 'created_at', x.created_at, 'created_by_name', e.full_name)
    FROM public.expenses x
    JOIN public.expense_categories c ON c.id = x.category_id AND c.organization_id = x.organization_id
    JOIN public.cash_accounts a ON a.id = x.cash_account_id AND a.organization_id = x.organization_id
    LEFT JOIN public.shifts s ON s.id = x.shift_id AND s.organization_id = x.organization_id
    LEFT JOIN public.employees e ON e.id = x.created_by AND e.organization_id = x.organization_id
    WHERE x.organization_id = p_org AND x.id = p_id
$$;

-- Readers of expenses and the report.
CREATE FUNCTION app.require_expense_read()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT (app.has_permission('expense.create') OR app.has_permission('cash.view')
            OR app.has_permission('report.financial')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: expense.create' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- 2. Categories ----------------------------------------------------------------------------------------

CREATE FUNCTION public.list_expense_categories(p_include_archived boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_expense_read();
    v_org := app.current_org_id();
    RETURN COALESCE((
        SELECT jsonb_agg(app.expense_category_json(v_org, c.id) ORDER BY c.name, c.id)
        FROM public.expense_categories c
        WHERE c.organization_id = v_org AND (COALESCE(p_include_archived, false) OR c.archived_at IS NULL)),
        '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.create_expense_category(p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_name text; v_id uuid;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    v_name := app.expense_category_name(p_name);
    BEGIN
        INSERT INTO public.expense_categories (organization_id, name, created_by, updated_by)
        VALUES (v_org, v_name, v_emp, v_emp) RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
    END;
    PERFORM app.write_audit('expense_category.created', 'expense_category', v_id, NULL,
        jsonb_build_object('name', v_name));
    RETURN app.expense_category_json(v_org, v_id);
END;
$$;

CREATE FUNCTION public.rename_expense_category(p_id uuid, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_name text; v_c public.expense_categories;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    SELECT * INTO v_c FROM public.expense_categories c WHERE c.id = p_id AND c.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_name := app.expense_category_name(p_name);
    IF v_name <> v_c.name THEN                                -- the same name: no change, no audit
        BEGIN
            UPDATE public.expense_categories c SET name = v_name, updated_by = v_emp WHERE c.id = p_id;
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'EXPENSE_CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
        END;
        PERFORM app.write_audit('expense_category.renamed', 'expense_category', p_id,
            jsonb_build_object('name', v_c.name), jsonb_build_object('name', v_name));
    END IF;
    RETURN app.expense_category_json(v_org, p_id);
END;
$$;

-- An archived category keeps its expenses and its name; it takes no new expense.
CREATE FUNCTION public.set_expense_category_archived(p_id uuid, p_archived boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_c public.expense_categories;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    SELECT * INTO v_c FROM public.expense_categories c WHERE c.id = p_id AND c.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    IF p_archived <> (v_c.archived_at IS NOT NULL) THEN       -- the same state: no change, no audit
        UPDATE public.expense_categories c
           SET archived_at = CASE WHEN p_archived THEN now() END, updated_by = v_emp
         WHERE c.id = p_id;
        PERFORM app.write_audit(CASE WHEN p_archived THEN 'expense_category.archived'
                                     ELSE 'expense_category.restored' END,
            'expense_category', p_id, NULL, jsonb_build_object('name', v_c.name));
    END IF;
    RETURN app.expense_category_json(v_org, p_id);
END;
$$;

-- 3. Expenses ------------------------------------------------------------------------------------------

-- The money leaves p_cash_account_id (a vault of p_branch_id), or, with p_from_shift, the drawer
-- of the caller's open shift (the branch is the shift's).
CREATE FUNCTION public.post_expense(p_category_id uuid, p_amount text, p_idempotency_key text,
                                    p_branch_id uuid DEFAULT NULL, p_cash_account_id uuid DEFAULT NULL,
                                    p_from_shift boolean DEFAULT false, p_note text DEFAULT NULL,
                                    p_receipt_file_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_x public.expenses; v_amount numeric(18,2); v_note text; v_archived timestamptz;
    v_account uuid; v_branch uuid; v_shift public.shifts; v_a public.cash_accounts; v_date date;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_x FROM public.expenses x WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.expense_json(v_org, v_x.id);              -- a repeat spends nothing
    END IF;

    SELECT c.archived_at INTO v_archived FROM public.expense_categories c
    WHERE c.id = p_category_id AND c.organization_id = v_org FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_archived IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_ARCHIVED' USING ERRCODE = 'P0001';
    END IF;
    v_amount := app.cash_amount(p_amount);
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 OR COALESCE(p_from_shift, false) = (p_cash_account_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an expense leaves a vault or the open shift, one of the two'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_receipt_file_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.files f
        WHERE f.id = p_receipt_file_id AND f.organization_id = v_org AND f.purpose = 'expense_receipt') THEN
        RAISE EXCEPTION 'FILE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    IF COALESCE(p_from_shift, false) THEN
        v_shift := app.require_open_shift(v_org, v_emp);
        PERFORM 1 FROM public.shifts s WHERE s.id = v_shift.id FOR UPDATE;
        v_branch := v_shift.branch_id;
        v_account := v_shift.drawer_account_id;
        PERFORM app.require_branch_access(v_branch);
    ELSE
        IF p_branch_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_branch_access(p_branch_id);
        v_branch := p_branch_id;
        v_a := app.payable_cash_account(v_org, p_cash_account_id, p_branch_id);
        v_account := v_a.id;
    END IF;

    v_date := app.org_today(v_org);
    INSERT INTO public.expenses (organization_id, number, branch_id, category_id, amount, cash_account_id,
                                 shift_id, note, receipt_file_id, business_date, idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_branch, 'expense'), v_branch, p_category_id, v_amount,
            v_account, v_shift.id, v_note, p_receipt_file_id, v_date, p_idempotency_key, v_emp)
    RETURNING * INTO v_x;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                       source_type, source_id, note, business_date, created_by, created_at)
    VALUES (v_org, v_account, v_branch, v_shift.id, -v_amount, 'expense', 'expense', v_x.id, v_x.number,
            v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('expense.posted', 'expense', v_x.id, NULL,
        jsonb_build_object('number', v_x.number, 'category_id', p_category_id, 'amount', v_amount::text,
                           'cash_account_id', v_account, 'shift_id', v_shift.id,
                           'receipt_file_id', p_receipt_file_id),
        v_note, v_branch);
    RETURN app.expense_json(v_org, v_x.id);
END;
$$;

-- The owner undoes an expense: a linked EX row and the money back where it came from. An expense
-- paid from a shift that is closed by now needs p_cash_account_id (a vault of the branch): the
-- drawer of a closed shift takes no money.
CREATE FUNCTION public.reverse_expense(p_id uuid, p_reason text, p_idempotency_key text,
                                       p_cash_account_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_x public.expenses; v_r public.expenses; v_reason text; v_date date;
    v_movement uuid; v_account uuid; v_shift uuid; v_a public.cash_accounts;
BEGIN
    v_emp := app.require_permission('expense.create');
    v_org := app.current_org_id();
    IF app.current_role() <> 'OWNER' THEN
        RAISE EXCEPTION 'APPROVAL_OWNER_ONLY' USING ERRCODE = '42501';
    END IF;
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_r FROM public.expenses x WHERE x.organization_id = v_org AND x.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF v_r.reverses_expense_id IS DISTINCT FROM p_id THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used for another expense' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.expense_json(v_org, v_r.id);
    END IF;

    SELECT * INTO v_x FROM public.expenses x WHERE x.id = p_id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_x.branch_id);
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 3 AND 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    IF v_x.reverses_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a reversal cannot be reversed' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.expenses r WHERE r.organization_id = v_org AND r.reverses_expense_id = v_x.id) THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED' USING ERRCODE = 'P0001';
    END IF;

    -- Where the money goes back: the same account, with the shift when it is still open.
    v_account := v_x.cash_account_id;
    v_shift := v_x.shift_id;
    IF v_x.shift_id IS NOT NULL
       AND (SELECT s.status FROM public.shifts s WHERE s.id = v_x.shift_id FOR UPDATE) <> 'open' THEN
        IF p_cash_account_id IS NULL THEN
            RAISE EXCEPTION 'VAULT_INVALID: the shift is closed, choose the vault the money goes back to'
                USING ERRCODE = 'P0001';
        END IF;
        v_a := app.payable_cash_account(v_org, p_cash_account_id, v_x.branch_id);
        v_account := v_a.id;
        v_shift := NULL;
    ELSIF p_cash_account_id IS NOT NULL AND p_cash_account_id <> v_x.cash_account_id THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: the money goes back to the account it left' USING ERRCODE = 'P0001';
    END IF;

    SELECT m.id INTO v_movement FROM public.cash_movements m
    WHERE m.organization_id = v_org AND m.source_type = 'expense' AND m.source_id = v_x.id
      AND m.reverses_movement_id IS NULL;
    v_date := app.org_today(v_org);
    INSERT INTO public.expenses (organization_id, number, branch_id, category_id, amount, cash_account_id,
                                 shift_id, note, receipt_file_id, reverses_expense_id, business_date,
                                 idempotency_key, created_by)
    VALUES (v_org, app.next_document_number(v_org, v_x.branch_id, 'expense'), v_x.branch_id, v_x.category_id,
            v_x.amount, v_account, v_shift, v_reason, NULL, v_x.id, v_date, p_idempotency_key, v_emp)
    RETURNING * INTO v_r;
    INSERT INTO public.cash_movements (organization_id, cash_account_id, branch_id, shift_id, amount, type,
                                       source_type, source_id, reverses_movement_id, note, business_date,
                                       created_by, created_at)
    VALUES (v_org, v_account, v_x.branch_id, v_shift, v_x.amount, 'expense', 'expense', v_r.id, v_movement,
            v_r.number, v_date, v_emp, clock_timestamp());

    PERFORM app.write_audit('expense.reversed', 'expense', v_x.id,
        jsonb_build_object('number', v_x.number, 'amount', v_x.amount::text),
        jsonb_build_object('reversal_id', v_r.id, 'reversal_number', v_r.number, 'cash_account_id', v_account),
        v_reason, v_x.branch_id, 'warning');
    RETURN app.expense_json(v_org, v_r.id);
END;
$$;

-- 4. Reads ---------------------------------------------------------------------------------------------

-- The caller's branches for a read: one branch (checked) or all of theirs.
CREATE FUNCTION app.expense_read_branches(p_org uuid, p_branch_id uuid)
RETURNS uuid[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = p_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        RETURN ARRAY[p_branch_id];
    END IF;
    RETURN COALESCE((SELECT array_agg(b.id) FROM public.branches b
                     WHERE b.organization_id = p_org AND app.has_branch_access(b.id)), ARRAY[]::uuid[]);
END;
$$;

-- p_include_reversals false: only the expenses that count (no reversals, no reversed expenses).
CREATE FUNCTION public.list_expenses(p_branch_id uuid DEFAULT NULL, p_category_id uuid DEFAULT NULL,
                                     p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                     p_include_reversals boolean DEFAULT true,
                                     p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    PERFORM app.require_expense_read();
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 OR p_from > p_to THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_category_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.expense_categories c WHERE c.id = p_category_id AND c.organization_id = v_org) THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_branches := app.expense_read_branches(v_org, p_branch_id);

    WITH found AS (
        SELECT x.id, x.business_date, x.created_at FROM public.expenses x
        WHERE x.organization_id = v_org AND x.branch_id = ANY(v_branches)
          AND (p_category_id IS NULL OR x.category_id = p_category_id)
          AND (p_from IS NULL OR x.business_date >= p_from)
          AND (p_to IS NULL OR x.business_date <= p_to)
          AND (COALESCE(p_include_reversals, true)
               OR (x.reverses_expense_id IS NULL
                   AND NOT EXISTS (SELECT 1 FROM public.expenses r
                                   WHERE r.organization_id = v_org AND r.reverses_expense_id = x.id)))
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.expense_json(v_org, f.id) ORDER BY f.business_date DESC, f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY business_date DESC, created_at DESC, id DESC
                  LIMIT p_limit OFFSET p_offset) f), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

-- Another shop's expense, or one of a branch the caller doesn't work in: not found.
CREATE FUNCTION public.get_expense(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branch uuid;
BEGIN
    PERFORM app.require_expense_read();
    v_org := app.current_org_id();
    SELECT x.branch_id INTO v_branch FROM public.expenses x WHERE x.id = p_id AND x.organization_id = v_org;
    IF NOT FOUND OR NOT app.has_branch_access(v_branch) THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.expense_json(v_org, p_id);
END;
$$;

-- What was spent per category in a period (business dates), reversed expenses left out.
CREATE FUNCTION public.expense_report(p_from date, p_to date, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[];
BEGIN
    PERFORM app.require_expense_read();
    v_org := app.current_org_id();
    IF p_from IS NULL OR p_to IS NULL OR p_from > p_to OR p_to - p_from > 366 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: period' USING ERRCODE = 'P0001';
    END IF;
    v_branches := app.expense_read_branches(v_org, p_branch_id);
    RETURN (
        WITH counted AS (
            SELECT x.category_id, x.amount FROM public.expenses x
            WHERE x.organization_id = v_org AND x.branch_id = ANY(v_branches)
              AND x.business_date BETWEEN p_from AND p_to AND x.reverses_expense_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.expenses r
                              WHERE r.organization_id = v_org AND r.reverses_expense_id = x.id)
        ), by_category AS (
            SELECT c.id, c.name, count(*) AS n, sum(k.amount)::numeric(18,2) AS total
            FROM counted k JOIN public.expense_categories c ON c.id = k.category_id
            GROUP BY c.id, c.name
        )
        SELECT jsonb_build_object(
            'from', p_from, 'to', p_to,
            'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('category_id', b.id, 'category_name', b.name,
                                   'count', b.n, 'total', b.total::text) ORDER BY b.total DESC, b.name)
                               FROM by_category b), '[]'::jsonb),
            'count', (SELECT count(*) FROM counted),
            'total', COALESCE((SELECT sum(k.amount) FROM counted k), 0)::numeric(18,2)::text));
END;
$$;

-- 5. Grants --------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.expense_category_json(uuid, uuid), app.expense_category_name(text),
    app.expense_json(uuid, uuid), app.require_expense_read(), app.expense_read_branches(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_expense_categories(boolean), public.create_expense_category(text),
    public.rename_expense_category(uuid, text), public.set_expense_category_archived(uuid, boolean),
    public.post_expense(uuid, text, text, uuid, uuid, boolean, text, uuid),
    public.reverse_expense(uuid, text, text, uuid),
    public.list_expenses(uuid, uuid, date, date, boolean, integer, integer), public.get_expense(uuid),
    public.expense_report(date, date, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_expense_categories(boolean), public.create_expense_category(text),
    public.rename_expense_category(uuid, text), public.set_expense_category_archived(uuid, boolean),
    public.post_expense(uuid, text, text, uuid, uuid, boolean, text, uuid),
    public.reverse_expense(uuid, text, text, uuid),
    public.list_expenses(uuid, uuid, date, date, boolean, integer, integer), public.get_expense(uuid),
    public.expense_report(date, date, uuid)
    TO authenticated;
