-- =============================================================================
-- L01 + N09 · Legal module, with the legal escalation status (EC-108, EC-88, D92)
--
-- The owner turns a defaulted contract into a legal case (from N04's legal referral or straight from
-- the contract). The case carries the court details, the assigned lawyer, its status (preparing ->
-- filed -> in court -> judgment -> closed), hearings, notes and documents. While a case is open the
-- contract and the customer account show a "legal" flag (this is N09: there is no flag column, the
-- reads compute it from legal_cases). A LAWYER employee sees only the cases assigned to them.
-- Islamic finance (docs/ISLAMIC_FINANCE_RULES.md, binding): nothing here ever changes what a
-- customer owes (rule 4): no fee, no cost, no charge, no payment. Money received through the legal
-- process is an ordinary N03 / N06 collection; the case only reads it.
--
-- Rules (docs/tasks/L01.md, owner defaults 24 Oct, D92):
--   1. Opening a case, assigning the lawyer: the owner only. One open case per contract.
--   2. The lawyer (role LAWYER) sees and changes only their own cases (app.can_see_legal_case).
--   3. Closing records an outcome and changes nothing on the contract or the customer.
--   4. Opening a case blocks the customer from new installment sales (R01 status 'blocked').
--
-- Numbers: contracts 0.63.0, 9 routes. Schema: three columns and a few CHECKs on the baseline legal
-- tables, no direct reads for authenticated. No new permission keys.
-- =============================================================================

-- 1. Schema ------------------------------------------------------------------------------------------

-- The three tables are empty on dev and prod (checked 24 Oct), so the new NOT NULL is safe; the
-- backfill is only a guard for a shop-local database that has rows.
ALTER TABLE public.legal_cases ADD COLUMN opened_on date;
UPDATE public.legal_cases lc
   SET opened_on = (lc.created_at AT TIME ZONE o.timezone)::date
  FROM public.organizations o WHERE o.id = lc.organization_id;
ALTER TABLE public.legal_cases ALTER COLUMN opened_on SET NOT NULL;

ALTER TABLE public.legal_cases ADD COLUMN outcome_kind text;
ALTER TABLE public.legal_cases
    ADD CONSTRAINT legal_cases_outcome_kind_check CHECK (outcome_kind IN
        ('paid', 'settled_out_of_court', 'judgment_enforced', 'withdrawn', 'dismissed_by_court', 'other')),
    ADD CONSTRAINT legal_cases_closed_outcome_check CHECK ((status = 'closed') = (outcome_kind IS NOT NULL)),
    ADD CONSTRAINT legal_cases_outcome_length_check CHECK (length(outcome) <= 1000);

ALTER TABLE public.legal_case_notes
    ADD CONSTRAINT legal_case_notes_note_length_check CHECK (length(note) BETWEEN 1 AND 2000);
ALTER TABLE public.legal_hearings
    ADD CONSTRAINT legal_hearings_outcome_length_check CHECK (length(outcome) <= 500),
    ADD CONSTRAINT legal_hearings_notes_length_check CHECK (length(notes) <= 2000);

-- No direct reads: the baseline gave every employee of the shop SELECT on these tables (a tenant
-- read policy plus the table grant). A lawyer must not read another lawyer's case, so everything
-- goes through the functions below, like N03 / N04 (decision 2).
DROP POLICY legal_cases_tenant_read ON public.legal_cases;
DROP POLICY legal_hearings_tenant_read ON public.legal_hearings;
DROP POLICY legal_case_notes_tenant_read ON public.legal_case_notes;
REVOKE ALL ON public.legal_cases, public.legal_hearings, public.legal_case_notes FROM PUBLIC, anon, authenticated;

-- 2. Who sees a case (decision 3) ------------------------------------------------------------------------

CREATE FUNCTION app.can_see_legal_case(p_lawyer_employee_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.current_role() = 'OWNER'
        OR COALESCE(app.has_permission('legal.view') AND p_lawyer_employee_id = app.current_employee_id(), false)
$$;

-- The start of every read: an employee of a shop with the legal module and legal.view (an expired
-- shop may still read).
CREATE FUNCTION app.legal_read_guard()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_org_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    PERFORM app.require_module('legal');
    IF NOT app.has_permission('legal.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: legal.view' USING ERRCODE = '42501';
    END IF;
    RETURN app.current_org_id();
END;
$$;

-- 3. Body helpers (shape checks only; every error is VALIDATION_FAILED: <field>) -------------------------

CREATE FUNCTION app.legal_body(p_body jsonb, p_allowed text[])
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_key text;
BEGIN
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(p_body) LOOP
        IF v_key <> ALL (p_allowed) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    RETURN p_body;
END;
$$;

-- The trimmed string, or NULL when the key is missing, null or blank.
CREATE FUNCTION app.legal_text(p_body jsonb, p_key text, p_max integer)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v text;
BEGIN
    IF NOT p_body ? p_key OR jsonb_typeof(p_body -> p_key) = 'null' THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p_body -> p_key) <> 'string' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
    END IF;
    v := NULLIF(btrim(p_body ->> p_key), '');
    IF length(v) > p_max THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

CREATE FUNCTION app.legal_uuid(p_body jsonb, p_key text)
RETURNS uuid LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    IF NOT p_body ? p_key OR jsonb_typeof(p_body -> p_key) = 'null' THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p_body -> p_key) <> 'string' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
    END IF;
    RETURN (p_body ->> p_key)::uuid;
EXCEPTION WHEN data_exception THEN
    RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
END;
$$;

-- A money string with at most two decimals (never a JSON number), or NULL when the key is missing.
CREATE FUNCTION app.legal_money(p_body jsonb, p_key text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    IF NOT p_body ? p_key THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p_body -> p_key) <> 'string' OR (p_body ->> p_key) !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
    END IF;
    RETURN (p_body ->> p_key)::numeric;
END;
$$;

CREATE FUNCTION app.legal_date(p_body jsonb, p_key text)
RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
BEGIN
    IF NOT p_body ? p_key OR jsonb_typeof(p_body -> p_key) = 'null' THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(p_body -> p_key) <> 'string' OR (p_body ->> p_key) !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
    END IF;
    RETURN (p_body ->> p_key)::date;
EXCEPTION WHEN data_exception THEN
    RAISE EXCEPTION 'VALIDATION_FAILED: %', p_key USING ERRCODE = 'P0001';
END;
$$;

-- The claim follows one rule everywhere (decisions 6 and 7): above 0 and not above what the
-- contract still owes. Court costs are never part of it (rule 4).
CREATE FUNCTION app.legal_check_claim(p_org uuid, p_contract_id uuid, p_claim numeric)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_remaining numeric := app.contract_remaining(p_org, p_contract_id);
BEGIN
    IF p_claim <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: claim_amount' USING ERRCODE = 'P0001';
    END IF;
    IF p_claim > v_remaining THEN
        RAISE EXCEPTION 'LEGAL_CLAIM_TOO_HIGH' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('remaining', v_remaining::numeric(18,2)::text)::text;
    END IF;
END;
$$;

-- The lawyer must be an active LAWYER employee of the shop (decision 5).
CREATE FUNCTION app.legal_check_lawyer(p_org uuid, p_employee_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.employees e
                   WHERE e.id = p_employee_id AND e.organization_id = p_org AND e.role = 'LAWYER'
                     AND e.is_active AND e.archived_at IS NULL) THEN
        RAISE EXCEPTION 'LAWYER_INVALID' USING ERRCODE = 'P0001';
    END IF;
END;
$$;

-- 4. Reads: the flag, the row, the detail ----------------------------------------------------------------

-- N09: the contract's open case, or NULL. An open case is a fact about the contract, so every
-- reader of the contract gets it; the id only opens for those who may see the case.
CREATE FUNCTION app.legal_flag_json(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', lc.id, 'number', lc.number, 'status', lc.status, 'opened_on', lc.opened_on)
    FROM public.legal_cases lc
    WHERE lc.organization_id = p_org AND lc.contract_id = p_contract_id AND lc.status <> 'closed'
$$;

-- The list row (decision: route 1). next_hearing_date is computed live, so a date that passed
-- overnight is never shown as "next".
CREATE FUNCTION app.legal_case_row_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', lc.id, 'number', lc.number, 'case_number', lc.case_number, 'court', lc.court,
        'case_type', lc.case_type, 'status', lc.status, 'opened_on', lc.opened_on,
        'next_hearing_date', CASE WHEN lc.status <> 'closed' THEN
            (SELECT min(h.hearing_date) FROM public.legal_hearings h
             WHERE h.organization_id = lc.organization_id AND h.case_id = lc.id AND h.outcome IS NULL
               AND h.hearing_date >= app.org_today(lc.organization_id)) END,
        'claim_amount', lc.claim_amount::text,
        'remaining', app.contract_remaining(lc.organization_id, lc.contract_id)::text,
        'contract', jsonb_build_object('id', c.id, 'number', c.number, 'branch_id', c.branch_id),
        'customer', jsonb_build_object('id', cu.id, 'name', cu.full_name, 'phone', cu.phones[1], 'status', cu.status),
        'lawyer', CASE WHEN le.id IS NULL THEN NULL
                       ELSE jsonb_build_object('id', le.id, 'name', le.full_name) END)
    FROM public.legal_cases lc
    JOIN public.contracts c ON c.id = lc.contract_id AND c.organization_id = lc.organization_id
    JOIN public.customers cu ON cu.id = lc.customer_id AND cu.organization_id = lc.organization_id
    LEFT JOIN public.employees le ON le.id = lc.lawyer_employee_id AND le.organization_id = lc.organization_id
    WHERE lc.organization_id = p_org AND lc.id = p_id
$$;

-- What was paid on the contract, split by the day the case was opened (decision 12). Same rows as
-- the contract's own paid amount: effective (not reversed) allocations to its schedule lines.
CREATE FUNCTION app.legal_case_amounts_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'claim_amount', lc.claim_amount::text,
        'total_payable', c.total_payable::text,
        'paid_before_case', COALESCE(sum(ea.amount) FILTER (WHERE ea.business_date < lc.opened_on), 0)::numeric(18,2)::text,
        'paid_since_opened', COALESCE(sum(ea.amount) FILTER (WHERE ea.business_date >= lc.opened_on), 0)::numeric(18,2)::text,
        'remaining', app.contract_remaining(lc.organization_id, lc.contract_id)::text)
    FROM public.legal_cases lc
    JOIN public.contracts c ON c.id = lc.contract_id AND c.organization_id = lc.organization_id
    LEFT JOIN public.v_effective_allocations ea ON ea.organization_id = lc.organization_id
         AND ea.contract_id = lc.contract_id AND ea.schedule_line_id IS NOT NULL
    WHERE lc.organization_id = p_org AND lc.id = p_id
    GROUP BY lc.id, c.id
$$;

-- The collections since the day the case was opened (N03 / N06 receipts, newest first, at most 50).
CREATE FUNCTION app.legal_case_collections_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'receipt_id', x.receipt_id, 'number', x.number, 'date', x.business_date,
               'amount', x.amount::text, 'taken_by', x.taken_by)
               ORDER BY x.business_date DESC, x.number DESC, x.receipt_id), '[]'::jsonb)
    FROM (
        SELECT r.id AS receipt_id, r.number, r.business_date, e.full_name AS taken_by,
               sum(ea.amount)::numeric(18,2) AS amount
        FROM public.legal_cases lc
        JOIN public.v_effective_allocations ea ON ea.organization_id = lc.organization_id
             AND ea.contract_id = lc.contract_id AND ea.schedule_line_id IS NOT NULL
             AND ea.direction = 'in' AND ea.business_date >= lc.opened_on
        JOIN public.payments p ON p.id = ea.payment_id AND p.organization_id = ea.organization_id
        JOIN public.payments r ON r.id = COALESCE(p.collection_id, p.id) AND r.organization_id = p.organization_id
        LEFT JOIN public.employees e ON e.id = r.received_by AND e.organization_id = r.organization_id
        WHERE lc.organization_id = p_org AND lc.id = p_id
        GROUP BY r.id, r.number, r.business_date, e.full_name
        ORDER BY r.business_date DESC, r.number DESC, r.id
        LIMIT 50) x
$$;

-- Route 2's answer. Every write answers with it too.
CREATE FUNCTION app.legal_case_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT app.legal_case_row_json(p_org, lc.id) || jsonb_build_object(
        'guarantors', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', g.id, 'name', g.full_name, 'relation', cg.relation)
                             ORDER BY g.full_name, g.id)
            FROM public.contract_guarantors k
            JOIN public.guarantors g ON g.id = k.guarantor_id AND g.organization_id = k.organization_id
            LEFT JOIN public.customer_guarantors cg ON cg.guarantor_id = k.guarantor_id
                 AND cg.customer_id = lc.customer_id AND cg.organization_id = k.organization_id
            WHERE k.organization_id = lc.organization_id AND k.contract_id = lc.contract_id), '[]'::jsonb),
        'hearings', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', h.id, 'hearing_date', h.hearing_date,
                                                'outcome', h.outcome, 'notes', h.notes, 'created_at', h.created_at)
                             ORDER BY h.hearing_date, h.created_at, h.id)
            FROM public.legal_hearings h WHERE h.organization_id = lc.organization_id AND h.case_id = lc.id), '[]'::jsonb),
        'notes', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'created_at', n.created_at,
                                                'created_by_name', ne.full_name)
                             ORDER BY n.created_at DESC, n.id)
            FROM public.legal_case_notes n
            LEFT JOIN public.employees ne ON ne.id = n.created_by AND ne.organization_id = n.organization_id
            WHERE n.organization_id = lc.organization_id AND n.case_id = lc.id), '[]'::jsonb),
        'amounts', app.legal_case_amounts_json(p_org, lc.id),
        'collections_since_opened', app.legal_case_collections_json(p_org, lc.id),
        'referral', (SELECT jsonb_build_object('id', a.id, 'business_date', a.business_date, 'days_late', a.days_late)
                     FROM public.overdue_actions a
                     WHERE a.organization_id = lc.organization_id AND a.legal_case_id = lc.id),
        'outcome_kind', lc.outcome_kind, 'outcome', lc.outcome, 'closed_at', lc.closed_at,
        'created_by_name', ce.full_name)
    FROM public.legal_cases lc
    LEFT JOIN public.employees ce ON ce.id = lc.created_by AND ce.organization_id = lc.organization_id
    WHERE lc.organization_id = p_org AND lc.id = p_id
$$;

-- A case for a write: locked, and the caller must be allowed to see it (another shop's id, another
-- lawyer's case and a missing id all answer the same).
CREATE FUNCTION app.legal_case_for_write(p_org uuid, p_id uuid)
RETURNS public.legal_cases LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE c public.legal_cases;
BEGIN
    SELECT * INTO c FROM public.legal_cases lc WHERE lc.id = p_id AND lc.organization_id = p_org FOR UPDATE;
    IF NOT FOUND OR NOT app.can_see_legal_case(c.lawyer_employee_id) THEN
        RAISE EXCEPTION 'LEGAL_CASE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN c;
END;
$$;

-- The earliest hearing on or after the shop's today with no outcome yet (or NULL), kept on the case.
CREATE FUNCTION app.legal_refresh_next_hearing(p_org uuid, p_case_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$
    UPDATE public.legal_cases lc
       SET next_hearing_date = CASE WHEN lc.status = 'closed' THEN NULL ELSE
           (SELECT min(h.hearing_date) FROM public.legal_hearings h
            WHERE h.organization_id = lc.organization_id AND h.case_id = lc.id AND h.outcome IS NULL
              AND h.hearing_date >= app.org_today(lc.organization_id)) END
     WHERE lc.organization_id = p_org AND lc.id = p_case_id
$$;

CREATE FUNCTION public.get_legal_case(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_lawyer uuid;
BEGIN
    v_org := app.legal_read_guard();
    SELECT lc.lawyer_employee_id INTO v_lawyer FROM public.legal_cases lc WHERE lc.id = p_id AND lc.organization_id = v_org;
    IF NOT FOUND OR NOT app.can_see_legal_case(v_lawyer) THEN
        RAISE EXCEPTION 'LEGAL_CASE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN app.legal_case_json(v_org, p_id);
END;
$$;

-- Open cases first (the soonest hearing first, none last), then the closed ones; newest opened
-- first inside a tie. Keyset cursor over (closed, hearing, -opened_on, id).
CREATE FUNCTION public.list_legal_cases(p_filters jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; f jsonb := COALESCE(p_filters, '{}'::jsonb); v_key text; v_status text; v_lawyer uuid; v_q text;
    v_like text; v_limit integer := 25; v_cur_closed integer; v_cur_h date; v_cur_neg integer; v_cur_id uuid;
    v_items jsonb; v_next text;
BEGIN
    v_org := app.legal_read_guard();
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF v_key NOT IN ('status', 'lawyer_id', 'q', 'limit', 'cursor') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
    BEGIN
        v_status := COALESCE(f ->> 'status', 'open');
        v_lawyer := (f ->> 'lawyer_id')::uuid;
        v_q := NULLIF(btrim(f ->> 'q'), '');
        v_limit := COALESCE((f ->> 'limit')::integer, 25);
        IF f ->> 'cursor' IS NOT NULL THEN
            v_cur_closed := split_part(f ->> 'cursor', '|', 1)::integer;
            v_cur_h := split_part(f ->> 'cursor', '|', 2)::date;
            v_cur_neg := split_part(f ->> 'cursor', '|', 3)::integer;
            v_cur_id := split_part(f ->> 'cursor', '|', 4)::uuid;
        END IF;
    EXCEPTION WHEN data_exception THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END;
    IF v_limit NOT BETWEEN 1 AND 100 OR v_status NOT IN ('open', 'closed', 'all') OR length(v_q) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: filters' USING ERRCODE = 'P0001';
    END IF;
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        v_lawyer := NULL;                                  -- a lawyer's list is their own cases, whatever they ask
    END IF;
    v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

    WITH base AS (
        SELECT lc.id, (lc.status = 'closed')::integer AS closed,
               CASE WHEN lc.status = 'closed' THEN 'infinity'::date ELSE COALESCE(
                   (SELECT min(h.hearing_date) FROM public.legal_hearings h
                    WHERE h.organization_id = lc.organization_id AND h.case_id = lc.id AND h.outcome IS NULL
                      AND h.hearing_date >= app.org_today(lc.organization_id)), 'infinity'::date) END AS h,
               (-(lc.opened_on - DATE '2000-01-01'))::integer AS neg
        FROM public.legal_cases lc
        JOIN public.contracts c ON c.id = lc.contract_id AND c.organization_id = lc.organization_id
        JOIN public.customers cu ON cu.id = lc.customer_id AND cu.organization_id = lc.organization_id
        WHERE lc.organization_id = v_org AND app.can_see_legal_case(lc.lawyer_employee_id)
          AND (v_status = 'all' OR (v_status = 'open' AND lc.status <> 'closed') OR (v_status = 'closed' AND lc.status = 'closed'))
          AND (v_lawyer IS NULL OR lc.lawyer_employee_id = v_lawyer)
          AND (v_q IS NULL OR lc.number ILIKE v_like || '%' OR lc.case_number ILIKE '%' || v_like || '%'
               OR c.number ILIKE v_like || '%' OR cu.full_name ILIKE '%' || v_like || '%'
               OR EXISTS (SELECT 1 FROM unnest(cu.phones) ph WHERE ph ILIKE '%' || v_like || '%'))
    ), page AS (
        SELECT b.*, row_number() OVER (ORDER BY b.closed, b.h, b.neg, b.id) AS n
        FROM base b
        WHERE v_cur_id IS NULL OR (b.closed, b.h, b.neg, b.id) > (v_cur_closed, v_cur_h, v_cur_neg, v_cur_id)
    )
    SELECT COALESCE(jsonb_agg(app.legal_case_row_json(v_org, p.id) ORDER BY p.n) FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit THEN p.closed::text || '|' || p.h::text || '|' || p.neg::text || '|' || p.id::text END) END
    INTO v_items, v_next
    FROM (SELECT * FROM page WHERE n <= v_limit + 1) p;
    RETURN jsonb_build_object('rows', v_items, 'next_cursor', v_next);
END;
$$;

-- The lawyers to pick from (the owner only).
CREATE FUNCTION public.list_lawyers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    v_org := app.legal_read_guard();
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'id', e.id, 'full_name', e.full_name, 'phone', e.phone,
                   'open_cases', (SELECT count(*) FROM public.legal_cases lc
                                  WHERE lc.organization_id = e.organization_id AND lc.lawyer_employee_id = e.id
                                    AND lc.status <> 'closed'))
                   ORDER BY e.full_name, e.id)
        FROM public.employees e
        WHERE e.organization_id = v_org AND e.role = 'LAWYER' AND e.is_active AND e.archived_at IS NULL), '[]'::jsonb));
END;
$$;

-- 5. Writes ---------------------------------------------------------------------------------------------

-- Opens a case (decision 6). One transaction: the case, its first note, the referral link and the
-- customer block, with the audit rows. It writes nothing to payments, schedule lines, charges or
-- any cash or ledger table.
CREATE FUNCTION public.open_legal_case(p_body jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_b jsonb; v_contract_id uuid; v_lawyer uuid; v_court text; v_type text; v_cnum text;
    v_claim numeric; v_note text; v_req jsonb; v_c public.contracts; v_existing public.legal_cases; v_prev jsonb;
    v_open uuid; v_overdue numeric; v_ref public.overdue_actions; v_id uuid := gen_random_uuid(); v_number text;
    v_old public.customer_status;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);

    v_b := app.legal_body(p_body, ARRAY['contract_id', 'lawyer_employee_id', 'court', 'case_type', 'case_number',
                                        'claim_amount', 'note']);
    v_contract_id := app.legal_uuid(v_b, 'contract_id');
    IF v_contract_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: contract_id' USING ERRCODE = 'P0001';
    END IF;
    v_lawyer := app.legal_uuid(v_b, 'lawyer_employee_id');
    v_court := app.legal_text(v_b, 'court', 200);
    v_type := app.legal_text(v_b, 'case_type', 100);
    v_cnum := app.legal_text(v_b, 'case_number', 100);
    v_claim := app.legal_money(v_b, 'claim_amount');
    v_note := app.legal_text(v_b, 'note', 2000);
    v_req := jsonb_strip_nulls(jsonb_build_object(
        'contract_id', v_contract_id, 'lawyer_employee_id', v_lawyer, 'court', v_court, 'case_type', v_type,
        'case_number', v_cnum, 'claim_amount', v_claim::numeric(18,2)::text, 'note', v_note));

    -- The same key and the same body is the same case; the same key and another body is a conflict.
    SELECT * INTO v_existing FROM public.legal_cases lc
    WHERE lc.organization_id = v_org AND lc.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        SELECT l.after -> 'request' INTO v_prev FROM public.audit_log l
        WHERE l.organization_id = v_org AND l.entity_type = 'legal_case' AND l.entity_id = v_existing.id
          AND l.action = 'legal.case_opened' ORDER BY l.created_at LIMIT 1;
        IF v_prev IS DISTINCT FROM v_req THEN
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: the key was used for another legal case' USING ERRCODE = 'P0001';
        END IF;
        RETURN app.legal_case_json(v_org, v_existing.id);
    END IF;

    SELECT * INTO v_c FROM public.contracts c WHERE c.id = v_contract_id AND c.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT lc.id INTO v_open FROM public.legal_cases lc
    WHERE lc.organization_id = v_org AND lc.contract_id = v_c.id AND lc.status <> 'closed';
    IF FOUND THEN
        RAISE EXCEPTION 'LEGAL_CASE_ALREADY_OPEN' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('legal_case_id', v_open)::text;
    END IF;
    SELECT cb.overdue_amount INTO v_overdue FROM public.v_contract_balances cb
    WHERE cb.organization_id = v_org AND cb.contract_id = v_c.id;
    SELECT * INTO v_ref FROM public.overdue_actions a
    WHERE a.organization_id = v_org AND a.contract_id = v_c.id AND a.kind = 'legal_referral' AND a.status = 'open'
    FOR UPDATE;
    IF v_c.status NOT IN ('active', 'rescheduled') OR (COALESCE(v_overdue, 0) <= 0 AND v_ref.id IS NULL) THEN
        RAISE EXCEPTION 'LEGAL_CONTRACT_NOT_DEFAULTED' USING ERRCODE = 'P0001';
    END IF;
    IF v_lawyer IS NOT NULL THEN
        PERFORM app.legal_check_lawyer(v_org, v_lawyer);
    END IF;
    IF v_claim IS NULL THEN
        v_claim := app.contract_remaining(v_org, v_c.id);
    ELSE
        PERFORM app.legal_check_claim(v_org, v_c.id, v_claim);
    END IF;

    v_number := app.next_document_number(v_org, v_c.branch_id, 'legal_case');
    INSERT INTO public.legal_cases (id, organization_id, number, contract_id, customer_id, case_number, court, case_type,
        lawyer_employee_id, status, claim_amount, opened_on, idempotency_key, created_by, updated_by)
    VALUES (v_id, v_org, v_number, v_c.id, v_c.customer_id, v_cnum, v_court, v_type, v_lawyer, 'preparing', v_claim,
        app.org_today(v_org), p_idempotency_key, v_emp, v_emp);
    IF v_note IS NOT NULL THEN
        INSERT INTO public.legal_case_notes (organization_id, case_id, note, created_by) VALUES (v_org, v_id, v_note, v_emp);
    END IF;
    IF v_ref.id IS NOT NULL THEN
        UPDATE public.overdue_actions SET status = 'case_opened', legal_case_id = v_id, handled_by = v_emp, handled_at = now()
        WHERE id = v_ref.id;
    END IF;

    -- Decision 5 (owner default): the customer can't take new installment sales. Written directly,
    -- as N04's job does (set_customer_status needs customer.edit). Already blocked: nothing to do.
    SELECT cu.status INTO v_old FROM public.customers cu WHERE cu.id = v_c.customer_id AND cu.organization_id = v_org FOR UPDATE;
    IF v_old IS DISTINCT FROM 'blocked' THEN
        UPDATE public.customers SET status = 'blocked', updated_at = now()
        WHERE id = v_c.customer_id AND organization_id = v_org;
        PERFORM app.write_audit('customer.status_set', 'customer', v_c.customer_id,
            p_before => jsonb_build_object('status', v_old),
            p_after => jsonb_build_object('status', 'blocked', 'by', 'legal_case'),
            p_reason => format('Legal case %s opened', v_number), p_severity => 'warning');
    END IF;

    PERFORM app.write_audit('legal.case_opened', 'legal_case', v_id,
        p_after => jsonb_build_object('legal_case_id', v_id, 'number', v_number, 'contract_id', v_c.id,
                                      'claim_amount', v_claim::numeric(18,2)::text, 'referral_id', v_ref.id,
                                      'request', v_req),
        p_branch_id => v_c.branch_id);
    RETURN app.legal_case_json(v_org, v_id);
END;
$$;

-- Changes the details (decision 7). The lawyer only by the owner; the claim only while preparing.
CREATE FUNCTION public.update_legal_case(p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; c public.legal_cases; v_b jsonb; v_before jsonb := '{}'::jsonb; v_after jsonb := '{}'::jsonb;
    v_court text; v_type text; v_cnum text; v_claim numeric; v_lawyer uuid; n public.legal_cases;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    v_org := app.current_org_id();
    c := app.legal_case_for_write(v_org, p_id);
    v_b := app.legal_body(p_body, ARRAY['court', 'case_type', 'case_number', 'claim_amount', 'lawyer_employee_id']);
    IF v_b = '{}'::jsonb THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    IF c.status = 'closed' THEN
        RAISE EXCEPTION 'LEGAL_CASE_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    n := c;
    IF v_b ? 'court' THEN
        n.court := app.legal_text(v_b, 'court', 200);
    END IF;
    IF v_b ? 'case_type' THEN
        n.case_type := app.legal_text(v_b, 'case_type', 100);
    END IF;
    IF v_b ? 'case_number' THEN
        n.case_number := app.legal_text(v_b, 'case_number', 100);
    END IF;
    IF v_b ? 'claim_amount' THEN
        v_claim := app.legal_money(v_b, 'claim_amount');
        IF c.status <> 'preparing' THEN
            RAISE EXCEPTION 'LEGAL_CASE_FILED' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.legal_check_claim(v_org, c.contract_id, v_claim);
        n.claim_amount := v_claim;
    END IF;
    IF v_b ? 'lawyer_employee_id' THEN
        IF app.current_role() IS DISTINCT FROM 'OWNER' THEN
            RAISE EXCEPTION 'PERMISSION_DENIED: owner' USING ERRCODE = '42501';
        END IF;
        n.lawyer_employee_id := app.legal_uuid(v_b, 'lawyer_employee_id');
        IF n.lawyer_employee_id IS NOT NULL THEN
            PERFORM app.legal_check_lawyer(v_org, n.lawyer_employee_id);
        END IF;
    END IF;
    -- A filed case keeps its lawyer, court and number (decision 5).
    IF c.status <> 'preparing' THEN
        IF n.lawyer_employee_id IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: lawyer_employee_id' USING ERRCODE = 'P0001';
        ELSIF n.court IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: court' USING ERRCODE = 'P0001';
        ELSIF n.case_number IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: case_number' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF n.court IS DISTINCT FROM c.court THEN
        v_before := v_before || jsonb_build_object('court', c.court); v_after := v_after || jsonb_build_object('court', n.court);
    END IF;
    IF n.case_type IS DISTINCT FROM c.case_type THEN
        v_before := v_before || jsonb_build_object('case_type', c.case_type); v_after := v_after || jsonb_build_object('case_type', n.case_type);
    END IF;
    IF n.case_number IS DISTINCT FROM c.case_number THEN
        v_before := v_before || jsonb_build_object('case_number', c.case_number); v_after := v_after || jsonb_build_object('case_number', n.case_number);
    END IF;
    IF n.claim_amount IS DISTINCT FROM c.claim_amount THEN
        v_before := v_before || jsonb_build_object('claim_amount', c.claim_amount::text); v_after := v_after || jsonb_build_object('claim_amount', n.claim_amount::text);
    END IF;
    IF n.lawyer_employee_id IS DISTINCT FROM c.lawyer_employee_id THEN
        v_before := v_before || jsonb_build_object('lawyer_employee_id', c.lawyer_employee_id);
        v_after := v_after || jsonb_build_object('lawyer_employee_id', n.lawyer_employee_id);
    END IF;
    IF v_after <> '{}'::jsonb THEN
        UPDATE public.legal_cases SET court = n.court, case_type = n.case_type, case_number = n.case_number,
            claim_amount = n.claim_amount, lawyer_employee_id = n.lawyer_employee_id, updated_at = now(), updated_by = v_emp
        WHERE id = c.id;
        PERFORM app.write_audit('legal.case_updated', 'legal_case', c.id, p_before => v_before, p_after => v_after,
            p_branch_id => (SELECT ct.branch_id FROM public.contracts ct WHERE ct.id = c.contract_id));
    END IF;
    RETURN app.legal_case_json(v_org, c.id);
END;
$$;

-- Moves the case along (decision 8): preparing -> filed -> in_court -> judgment, judgment ->
-- in_court (an appeal), any open status -> closed with an outcome. A closed case never reopens.
CREATE FUNCTION public.set_legal_case_status(p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; c public.legal_cases; v_b jsonb; v_to text; v_kind text; v_outcome text; v_ok boolean;
    v_branch uuid;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    v_org := app.current_org_id();
    c := app.legal_case_for_write(v_org, p_id);
    v_b := app.legal_body(p_body, ARRAY['status', 'outcome_kind', 'outcome']);
    IF jsonb_typeof(v_b -> 'status') IS DISTINCT FROM 'string'
       OR (v_b ->> 'status') NOT IN ('preparing', 'filed', 'in_court', 'judgment', 'closed') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    v_to := v_b ->> 'status';
    v_kind := app.legal_text(v_b, 'outcome_kind', 40);
    v_outcome := app.legal_text(v_b, 'outcome', 1000);
    v_ok := (c.status::text, v_to) IN (('preparing', 'filed'), ('filed', 'in_court'), ('in_court', 'judgment'),
                                       ('judgment', 'in_court'))
            OR (c.status <> 'closed' AND v_to = 'closed');
    IF NOT v_ok THEN
        RAISE EXCEPTION 'LEGAL_STATUS_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('from', c.status, 'to', v_to)::text;
    END IF;
    IF v_to <> 'closed' AND (v_kind IS NOT NULL OR v_outcome IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: outcome_kind' USING ERRCODE = 'P0001';
    END IF;
    IF v_to = 'filed' THEN
        IF c.lawyer_employee_id IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: lawyer_employee_id' USING ERRCODE = 'P0001';
        ELSIF c.court IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: court' USING ERRCODE = 'P0001';
        ELSIF c.case_number IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: case_number' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    IF v_to = 'closed' THEN
        IF v_kind IS NULL OR v_kind NOT IN ('paid', 'settled_out_of_court', 'judgment_enforced', 'withdrawn',
                                            'dismissed_by_court', 'other') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: outcome_kind' USING ERRCODE = 'P0001';
        END IF;
        IF v_kind = 'other' AND v_outcome IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: outcome' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT ct.branch_id INTO v_branch FROM public.contracts ct WHERE ct.id = c.contract_id;
    IF v_to = 'closed' THEN
        UPDATE public.legal_cases SET status = 'closed', closed_at = now(), outcome_kind = v_kind, outcome = v_outcome,
            next_hearing_date = NULL, updated_at = now(), updated_by = v_emp
        WHERE id = c.id;
        PERFORM app.write_audit('legal.case_closed', 'legal_case', c.id,
            p_before => jsonb_build_object('status', c.status),
            p_after => jsonb_build_object('status', 'closed', 'outcome_kind', v_kind), p_reason => v_outcome,
            p_branch_id => v_branch);
    ELSE
        UPDATE public.legal_cases SET status = v_to::public.legal_status, updated_at = now(), updated_by = v_emp
        WHERE id = c.id;
        PERFORM app.write_audit('legal.case_status_changed', 'legal_case', c.id,
            p_before => jsonb_build_object('status', c.status), p_after => jsonb_build_object('status', v_to),
            p_branch_id => v_branch);
    END IF;
    RETURN app.legal_case_json(v_org, c.id);
END;
$$;

CREATE FUNCTION public.add_legal_hearing(p_case_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; c public.legal_cases; v_b jsonb; v_date date; v_notes text; v_id uuid;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    v_org := app.current_org_id();
    c := app.legal_case_for_write(v_org, p_case_id);
    v_b := app.legal_body(p_body, ARRAY['hearing_date', 'notes']);
    v_date := app.legal_date(v_b, 'hearing_date');
    IF v_date IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: hearing_date' USING ERRCODE = 'P0001';
    END IF;
    v_notes := app.legal_text(v_b, 'notes', 2000);
    IF c.status = 'closed' THEN
        RAISE EXCEPTION 'LEGAL_CASE_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.legal_hearings (organization_id, case_id, hearing_date, notes, created_by, updated_by)
    VALUES (v_org, c.id, v_date, v_notes, v_emp, v_emp) RETURNING id INTO v_id;
    PERFORM app.legal_refresh_next_hearing(v_org, c.id);
    PERFORM app.write_audit('legal.hearing_added', 'legal_case', c.id,
        p_after => jsonb_build_object('hearing_id', v_id, 'hearing_date', v_date),
        p_branch_id => (SELECT ct.branch_id FROM public.contracts ct WHERE ct.id = c.contract_id));
    RETURN app.legal_case_json(v_org, c.id);
END;
$$;

CREATE FUNCTION public.update_legal_hearing(p_case_id uuid, p_hearing_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; c public.legal_cases; v_b jsonb; h public.legal_hearings; n public.legal_hearings;
    v_before jsonb := '{}'::jsonb; v_after jsonb := '{}'::jsonb;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    v_org := app.current_org_id();
    c := app.legal_case_for_write(v_org, p_case_id);
    SELECT * INTO h FROM public.legal_hearings x
    WHERE x.id = p_hearing_id AND x.case_id = c.id AND x.organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HEARING_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_b := app.legal_body(p_body, ARRAY['hearing_date', 'outcome', 'notes']);
    IF v_b = '{}'::jsonb THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    n := h;
    IF v_b ? 'hearing_date' THEN
        n.hearing_date := app.legal_date(v_b, 'hearing_date');
        IF n.hearing_date IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: hearing_date' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    IF v_b ? 'outcome' THEN
        n.outcome := app.legal_text(v_b, 'outcome', 500);
    END IF;
    IF v_b ? 'notes' THEN
        n.notes := app.legal_text(v_b, 'notes', 2000);
    END IF;
    IF c.status = 'closed' THEN
        RAISE EXCEPTION 'LEGAL_CASE_CLOSED' USING ERRCODE = 'P0001';
    END IF;
    IF n.hearing_date IS DISTINCT FROM h.hearing_date THEN
        v_before := v_before || jsonb_build_object('hearing_date', h.hearing_date); v_after := v_after || jsonb_build_object('hearing_date', n.hearing_date);
    END IF;
    IF n.outcome IS DISTINCT FROM h.outcome THEN
        v_before := v_before || jsonb_build_object('outcome', h.outcome); v_after := v_after || jsonb_build_object('outcome', n.outcome);
    END IF;
    IF n.notes IS DISTINCT FROM h.notes THEN
        v_before := v_before || jsonb_build_object('notes', h.notes); v_after := v_after || jsonb_build_object('notes', n.notes);
    END IF;
    IF v_after <> '{}'::jsonb THEN
        UPDATE public.legal_hearings SET hearing_date = n.hearing_date, outcome = n.outcome, notes = n.notes,
            updated_at = now(), updated_by = v_emp
        WHERE id = h.id;
        PERFORM app.legal_refresh_next_hearing(v_org, c.id);
        PERFORM app.write_audit('legal.hearing_updated', 'legal_case', c.id,
            p_before => v_before || jsonb_build_object('hearing_id', h.id), p_after => v_after || jsonb_build_object('hearing_id', h.id),
            p_branch_id => (SELECT ct.branch_id FROM public.contracts ct WHERE ct.id = c.contract_id));
    END IF;
    RETURN app.legal_case_json(v_org, c.id);
END;
$$;

-- Notes are append-only (the baseline blocks update and delete); allowed on a closed case too.
CREATE FUNCTION public.add_legal_case_note(p_case_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; c public.legal_cases; v_b jsonb; v_note text; v_id uuid;
BEGIN
    v_emp := app.require_permission('legal.manage');
    PERFORM app.require_module('legal');
    v_org := app.current_org_id();
    c := app.legal_case_for_write(v_org, p_case_id);
    v_b := app.legal_body(p_body, ARRAY['note']);
    v_note := app.legal_text(v_b, 'note', 2000);
    IF v_note IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.legal_case_notes (organization_id, case_id, note, created_by)
    VALUES (v_org, c.id, v_note, v_emp) RETURNING id INTO v_id;
    PERFORM app.write_audit('legal.note_added', 'legal_case', c.id,
        p_after => jsonb_build_object('note_id', v_id),
        p_branch_id => (SELECT ct.branch_id FROM public.contracts ct WHERE ct.id = c.contract_id));
    RETURN app.legal_case_json(v_org, c.id);
END;
$$;

-- 6. The flag on the contract, the customer account and the overdue list (decision 13) -----------------

-- The contract answer carries legal_case (M02's body, one key added).
CREATE OR REPLACE FUNCTION app.contract_json(p_org uuid, p_id uuid)
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
        'created_at', c.created_at, 'created_by_name', e.full_name, 'migration_source', c.migration_source,
        'legal_case', app.legal_flag_json(c.organization_id, c.id),
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
$$;;

-- The customer account's contract rows carry it too (M02's body, one key added).
CREATE OR REPLACE FUNCTION app.customer_contract_json(p_org uuid, p_contract_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', c.id, 'number', c.number, 'status', c.status,
        'branch', jsonb_build_object('id', b.id, 'name', b.name),
        'sale_id', c.sale_id, 'sale_number', s.number, 'issued_at', c.created_at,
        'is_migrated', c.is_migrated, 'migration_source', c.migration_source,
        'cash_price', c.cash_price::text, 'down_payment', c.down_payment::text,
        'financed_amount', c.financed_amount::text, 'markup_amount', c.markup_amount::text,
        'total_payable', c.total_payable::text,
        'contract_total', app.customer_contract_total(p_org, c.id)::text,
        'paid', cb.paid::text, 'remaining', cb.remaining::text, 'fees_due', cb.fees_due::text,
        'overdue_amount', cb.overdue_amount::text, 'overdue_lines', cb.overdue_lines,
        'max_days_late', cb.max_days_late, 'next_due_date', cb.next_due_date,
        'installments_count', c.installments_count, 'frequency', c.frequency,
        'first_due_date', c.first_due_date,
        'legal_case', app.legal_flag_json(c.organization_id, c.id))
    FROM public.contracts c
    JOIN public.branches b ON b.id = c.branch_id AND b.organization_id = c.organization_id
    JOIN public.v_contract_balances cb ON cb.contract_id = c.id AND cb.organization_id = c.organization_id
    LEFT JOIN public.sales s ON s.id = c.sale_id AND s.organization_id = c.organization_id
    WHERE c.organization_id = p_org AND c.id = p_contract_id
$$;;

-- The overdue list rows carry it (N06's body, one key added).
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
                                  ORDER BY a.business_date DESC LIMIT 1),
               'legal_case', (SELECT jsonb_build_object('id', lc.id, 'number', lc.number, 'status', lc.status)
                              FROM public.legal_cases lc
                              WHERE lc.organization_id = v_org AND lc.contract_id = p.contract_id AND lc.status <> 'closed'))
               ORDER BY p.max_days_late DESC, p.contract_id) FILTER (WHERE p.n <= v_limit), '[]'::jsonb),
           CASE WHEN count(*) > v_limit
                THEN max(CASE WHEN p.n = v_limit THEN p.max_days_late::text || '|' || p.contract_id::text END) END,
           (SELECT t FROM totals)
    INTO v_items, v_next, v_totals
    FROM page p;
    RETURN jsonb_build_object('items', v_items, 'next_cursor', v_next, 'totals', v_totals);
END;
$$;;

-- 7. Grants -----------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.can_see_legal_case(uuid), app.legal_read_guard(), app.legal_body(jsonb, text[]),
    app.legal_text(jsonb, text, integer), app.legal_uuid(jsonb, text), app.legal_money(jsonb, text),
    app.legal_date(jsonb, text), app.legal_check_claim(uuid, uuid, numeric), app.legal_check_lawyer(uuid, uuid),
    app.legal_flag_json(uuid, uuid), app.legal_case_row_json(uuid, uuid), app.legal_case_amounts_json(uuid, uuid),
    app.legal_case_collections_json(uuid, uuid), app.legal_case_json(uuid, uuid), app.legal_case_for_write(uuid, uuid),
    app.legal_refresh_next_hearing(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_legal_case(uuid), public.list_legal_cases(jsonb), public.list_lawyers(),
    public.open_legal_case(jsonb, text), public.update_legal_case(uuid, jsonb), public.set_legal_case_status(uuid, jsonb),
    public.add_legal_hearing(uuid, jsonb), public.update_legal_hearing(uuid, uuid, jsonb),
    public.add_legal_case_note(uuid, jsonb)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_legal_case(uuid), public.list_legal_cases(jsonb), public.list_lawyers(),
    public.open_legal_case(jsonb, text), public.update_legal_case(uuid, jsonb), public.set_legal_case_status(uuid, jsonb),
    public.add_legal_hearing(uuid, jsonb), public.update_legal_hearing(uuid, uuid, jsonb),
    public.add_legal_case_note(uuid, jsonb)
    TO authenticated;
