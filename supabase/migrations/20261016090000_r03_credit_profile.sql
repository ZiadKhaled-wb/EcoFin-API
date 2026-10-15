-- =============================================================================
-- R03 · Credit profile and limit (EC-65, D72)
--
-- Before the shop lends its own money, the server knows how much more credit a customer can get.
-- A customer has an explicit credit limit (customers.credit_limit, set by a user with
-- credit.approve; a suggestion comes from the shop settings: monthly income x multiple, shown but
-- never used by the check). Exposure = the unpaid principal of the customer's open contracts
-- (v_contract_balances; statuses active and rescheduled). Available credit = limit - exposure.
-- The profile adds a 0-100 credit score (the shop's weights x four components) and the payment
-- behaviour. One server function (app.check_customer_credit) decides whether an installment sale
-- of a given financed amount is allowed: above the available credit, below the minimum score or
-- for a customer on watch it is refused unless a credit.approve user approved an exception for
-- that customer and amount (an approval on the spot, copied from S03, valid 24 hours, one
-- contract). N02 calls the function inside its transaction; a deferred constraint trigger on
-- contracts is the safety net for any other writer.
--
-- Numbered after the newest migration on main plus R04's (D39). Everything below is NEW except:
--   * app.approvals_freeze is re-created from its latest version (S03) so that an approved
--     credit_exception may also get its entity_id written once; nothing else changes in it;
--   * the baseline CHECK approvals_check1 ("no self-approval") is replaced by one that exempts
--     the kind credit_exception, because the owner of a one-person shop may decide their own
--     request (D72, to confirm); decide_credit_exception refuses everyone else (APPROVAL_SELF).
-- No table or column changes. customers.credit_limit exists since the baseline; R01's
-- update_customer keeps refusing it.
--
-- Rules (D72):
--   1. The limit is explicit: customers.credit_limit is the only limit; a new customer has 0, so
--      no installment sale passes without a limit or an exception.
--   2. set_customer_credit_limit: credit.approve; 0..99 999 999.99; a reason (3-300) is required
--      when the limit goes up; the same value again is no change and no audit row; a limit below
--      the exposure is allowed; archived customers are refused.
--   3. History: the last 10 customer.credit_limit_set audit rows, newest first.
--   4. Score 0-100 (integer, half-up) = sum(weight x component): guarantors (active links / 2,
--      max 1), income (1 when monthly income > 0), identity (0.5 valid national ID + 0.5 an ID
--      photo), residence (0 until R05).
--   5. Behaviour from v_schedule_line_status over the customer's current lines (superseded ones
--      excluded): on-time share, days late, overdue amount, contract counts.
--   6. app.check_customer_credit raises, in this order: CUSTOMER_NOT_FOUND; CUSTOMER_BLOCKED (blocked
--      or archived, never overridable); then limit / score / watch reasons: CREDIT_LIMIT_EXCEEDED,
--      CREDIT_SCORE_TOO_LOW, CREDIT_CUSTOMER_WATCH, or CREDIT_APPROVAL_INVALID for a bad exception.
--   7. Exceptions: request (sale.create or credit.approve), decide (credit.approve; not the
--      requester unless the decider is the OWNER), cancel (the requester, while pending).
--   8. trg_contracts_credit_check: at commit a contract above the available credit (exposure
--      without the new contract) needs an approved credit_exception whose entity_id is the
--      contract; migrated (M02) contracts are exempt; a blocked customer is refused.
-- =============================================================================

-- 1. approvals: the one-time use of a credit exception, and the owner deciding their own ----------

CREATE OR REPLACE FUNCTION app.approvals_freeze()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF OLD.status IN ('approved', 'rejected', 'cancelled') THEN
        -- The one change after the decision: an approved discount or credit exception approval is
        -- used by its sale or contract (the document's id is written once).
        IF OLD.kind IN ('discount_above_cap', 'credit_exception') AND OLD.status = 'approved'
           AND OLD.entity_id IS NULL AND NEW.entity_id IS NOT NULL
           AND (to_jsonb(NEW) - 'entity_id' - 'updated_at') = (to_jsonb(OLD) - 'entity_id' - 'updated_at') THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'DOCUMENT_FINAL: %.% is % and can no longer change',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.status USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

ALTER TABLE public.approvals DROP CONSTRAINT approvals_check1;
ALTER TABLE public.approvals ADD CONSTRAINT approvals_no_self_approval
    CHECK (decided_by IS NULL OR decided_by <> requested_by OR kind = 'credit_exception');

-- 2. Helpers (schema app, no grants) ---------------------------------------------------------------

-- How long an approved exception stays usable.
CREATE FUNCTION app.credit_exception_ttl()
RETURNS interval LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT interval '24 hours' $$;

-- A money text from a function argument: ASCII digits, at most 8 before and 2 after the point
-- (so at most 99 999 999.99). p_positive: zero is refused too.
CREATE FUNCTION app.parse_credit_amount(p_text text, p_name text, p_positive boolean)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v numeric;
BEGIN
    IF p_text IS NULL OR p_text !~ '^[0-9]{1,8}(\.[0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_name USING ERRCODE = 'P0001';
    END IF;
    v := p_text::numeric;
    IF p_positive AND v <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', p_name USING ERRCODE = 'P0001';
    END IF;
    RETURN v;
END;
$$;

-- Unpaid principal of the customer's open contracts (v_contract_balances), optionally without one
-- contract (the safety net asks "what did the customer owe before this contract?").
CREATE FUNCTION app.customer_exposure(p_org uuid, p_customer_id uuid, p_exclude_contract uuid DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT COALESCE(SUM(cb.principal_outstanding), 0)::numeric(18,2)
    FROM public.v_contract_balances cb
    WHERE cb.organization_id = p_org AND cb.customer_id = p_customer_id
      AND cb.status IN ('active', 'rescheduled')
      AND cb.contract_id IS DISTINCT FROM p_exclude_contract
$$;

-- Monthly income x the shop's multiple, rounded down to the pound; NULL when either is missing.
-- Only a suggestion: the check never uses it.
CREATE FUNCTION app.customer_suggested_limit(p_org uuid, p_customer_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE WHEN c.monthly_income IS NULL OR s.credit_limit_income_multiple IS NULL THEN NULL
                ELSE LEAST(floor(c.monthly_income * s.credit_limit_income_multiple), 99999999) END
    FROM public.customers c
    LEFT JOIN public.org_settings s ON s.organization_id = c.organization_id
    WHERE c.id = p_customer_id AND c.organization_id = p_org
$$;

-- {score, min_score, components[{key, weight, value, points}]}: the shop's weights x components in
-- 0..1; score = the sum of weight x value, rounded half-up, 0..100. Read only, nothing is stored.
CREATE FUNCTION app.customer_credit_score(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_c public.customers; v_s public.org_settings; v_guarantors integer; v_photos integer;
    v_id_ok boolean; v_comp jsonb; v_total numeric;
BEGIN
    SELECT * INTO v_c FROM public.customers WHERE id = p_customer_id AND organization_id = p_org;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_s FROM public.org_settings WHERE organization_id = p_org;
    SELECT count(*) INTO v_guarantors
    FROM public.customer_guarantors cg
    JOIN public.guarantors g ON g.id = cg.guarantor_id AND g.organization_id = cg.organization_id
    WHERE cg.organization_id = p_org AND cg.customer_id = p_customer_id AND g.archived_at IS NULL;
    SELECT count(*) INTO v_photos FROM public.files f
    WHERE f.organization_id = p_org AND f.entity_type = 'customer' AND f.entity_id = p_customer_id
      AND f.purpose = 'customer_id';
    v_id_ok := (SELECT p.birth_date IS NOT NULL FROM app.parse_national_id(v_c.national_id) p);

    WITH c(ord, key, value) AS (VALUES
        (1, 'guarantors', LEAST(v_guarantors / 2.0, 1.0)),
        (2, 'income',     CASE WHEN COALESCE(v_c.monthly_income, 0) > 0 THEN 1.0 ELSE 0.0 END),
        -- TODO(R05): the latest approved field survey fills residence; 0 until then.
        (3, 'residence',  0.0),
        (4, 'identity',   (CASE WHEN v_id_ok THEN 0.5 ELSE 0.0 END) + (CASE WHEN v_photos > 0 THEN 0.5 ELSE 0.0 END))),
    w AS (SELECT c.ord, c.key, c.value, COALESCE((v_s.credit_score_weights ->> c.key)::numeric, 0) AS weight FROM c)
    SELECT jsonb_agg(jsonb_build_object('key', w.key, 'weight', w.weight, 'value', round(w.value, 2),
                                        'points', round(w.weight * w.value, 2)) ORDER BY w.ord),
           COALESCE(sum(w.weight * w.value), 0)
    INTO v_comp, v_total FROM w;
    RETURN jsonb_build_object('score', LEAST(GREATEST(round(v_total, 0), 0), 100)::integer,
                              'min_score', v_s.credit_min_score, 'components', v_comp);
END;
$$;

-- The payment behaviour from the customer's current schedule lines (superseded ones excluded) that
-- are due (due date <= today in the shop's timezone). A line is on time when its payments up to its
-- due date (by the payment's business date) cover it; days late = the day it was fully paid (today
-- while it is not) minus the due date. Money as text; nulls when no line is due yet.
CREATE FUNCTION app.customer_credit_behaviour(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_today date; v_r record; v_open integer; v_completed integer;
BEGIN
    v_today := app.org_today(p_org);
    SELECT count(*) FILTER (WHERE c.status IN ('active', 'rescheduled')),
           count(*) FILTER (WHERE c.status = 'completed')
    INTO v_open, v_completed
    FROM public.contracts c WHERE c.organization_id = p_org AND c.customer_id = p_customer_id;

    WITH due AS (
        SELECT ls.schedule_line_id, ls.due_date, ls.amount, ls.remaining, ls.status
        FROM public.v_schedule_line_status ls
        JOIN public.contracts c ON c.id = ls.contract_id AND c.organization_id = ls.organization_id
        WHERE ls.organization_id = p_org AND c.customer_id = p_customer_id
          AND NOT ls.superseded AND ls.due_date <= v_today),
    paid AS (
        SELECT ea.schedule_line_id, ea.business_date,
               sum(ea.amount) OVER (PARTITION BY ea.schedule_line_id
                                    ORDER BY ea.business_date, ea.paid_at, ea.id) AS running
        FROM public.v_effective_allocations ea
        WHERE ea.organization_id = p_org AND ea.direction = 'in'
          AND ea.schedule_line_id IN (SELECT d.schedule_line_id FROM due d)),
    settled AS (
        SELECT d.schedule_line_id, min(p.business_date) AS paid_on
        FROM due d JOIN paid p ON p.schedule_line_id = d.schedule_line_id AND p.running >= d.amount
        GROUP BY d.schedule_line_id),
    per_line AS (
        SELECT d.*, s.paid_on,
               (s.paid_on IS NOT NULL AND s.paid_on <= d.due_date) AS on_time,
               GREATEST(COALESCE(s.paid_on, v_today) - d.due_date, 0) AS days_late
        FROM due d LEFT JOIN settled s ON s.schedule_line_id = d.schedule_line_id)
    SELECT count(*)::integer AS due_lines,
           CASE WHEN count(*) = 0 THEN NULL
                ELSE round(100.0 * count(*) FILTER (WHERE on_time) / count(*), 0)::integer END AS on_time_pct,
           max(days_late)::integer AS max_days_late,
           COALESCE(sum(remaining) FILTER (WHERE status = 'overdue'), 0)::numeric(18,2) AS overdue_amount,
           (count(*) FILTER (WHERE status = 'overdue'))::integer AS overdue_lines
    INTO v_r FROM per_line;

    RETURN jsonb_build_object('due_lines', v_r.due_lines, 'on_time_pct', v_r.on_time_pct,
        'max_days_late', v_r.max_days_late, 'current_overdue_amount', v_r.overdue_amount::text,
        'overdue_lines', v_r.overdue_lines, 'open_contracts', v_open, 'completed_contracts', v_completed);
END;
$$;

-- The profile of one customer (the contract's CreditProfile). Available is never negative: the
-- amount over the limit is shown on its own.
CREATE FUNCTION app.customer_credit_profile_json(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_c public.customers; v_exposure numeric; v_score jsonb;
BEGIN
    SELECT * INTO v_c FROM public.customers WHERE id = p_customer_id AND organization_id = p_org;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_exposure := app.customer_exposure(p_org, p_customer_id);
    v_score := app.customer_credit_score(p_org, p_customer_id);
    RETURN jsonb_build_object(
        'customer_id', v_c.id, 'status', v_c.status,
        'credit_limit', v_c.credit_limit::numeric(18,2)::text,
        'suggested_limit', app.customer_suggested_limit(p_org, p_customer_id)::numeric(18,2)::text,
        'exposure', v_exposure::numeric(18,2)::text,
        'available', GREATEST(v_c.credit_limit - v_exposure, 0)::numeric(18,2)::text,
        'over_limit_by', GREATEST(v_exposure - v_c.credit_limit, 0)::numeric(18,2)::text,
        'score', v_score -> 'score', 'min_score', v_score -> 'min_score', 'components', v_score -> 'components',
        'behaviour', app.customer_credit_behaviour(p_org, p_customer_id),
        'store_credit', COALESCE((SELECT x.store_credit::numeric(18,2)::text FROM public.v_customer_exposure x
                                  WHERE x.organization_id = p_org AND x.customer_id = p_customer_id), '0.00'),
        'limit_history', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('at', h.created_at, 'by_name', e.full_name,
                                                'from', h.before ->> 'credit_limit', 'to', h.after ->> 'credit_limit',
                                                'reason', h.reason) ORDER BY h.created_at DESC, h.id DESC)
            FROM (SELECT a.* FROM public.audit_log a
                  WHERE a.organization_id = p_org AND a.action = 'customer.credit_limit_set'
                    AND a.entity_type = 'customer' AND a.entity_id = p_customer_id
                  ORDER BY a.created_at DESC, a.id DESC LIMIT 10) h
            LEFT JOIN public.employees e ON e.id = h.employee_id AND e.organization_id = h.organization_id), '[]'::jsonb));
END;
$$;

-- What stands in the way of an installment sale of p_financed_amount: the reasons (limit, score,
-- watch, in that order) with the numbers. The same object is the detail of the credit errors.
-- The caller has checked that the customer exists in the shop.
CREATE FUNCTION app.credit_reasons(p_org uuid, p_customer_id uuid, p_financed_amount numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_c public.customers; v_exposure numeric; v_score jsonb; v_reasons jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_c FROM public.customers WHERE id = p_customer_id AND organization_id = p_org;
    v_exposure := app.customer_exposure(p_org, p_customer_id);
    v_score := app.customer_credit_score(p_org, p_customer_id);
    IF p_financed_amount > v_c.credit_limit - v_exposure THEN
        v_reasons := v_reasons || to_jsonb('limit'::text);
    END IF;
    IF (v_score ->> 'score')::integer < (v_score ->> 'min_score')::integer THEN
        v_reasons := v_reasons || to_jsonb('score'::text);
    END IF;
    IF v_c.status = 'watch' THEN
        v_reasons := v_reasons || to_jsonb('watch'::text);
    END IF;
    RETURN jsonb_build_object(
        'limit', v_c.credit_limit::numeric(18,2)::text, 'exposure', v_exposure::numeric(18,2)::text,
        'available', GREATEST(v_c.credit_limit - v_exposure, 0)::numeric(18,2)::text,
        'requested', p_financed_amount::numeric(18,2)::text,
        'score', v_score -> 'score', 'min_score', v_score -> 'min_score', 'reasons', v_reasons);
END;
$$;

-- An approved, unused, unexpired exception of this customer for at least p_financed_amount (the
-- newest), or NULL.
CREATE FUNCTION app.credit_exception_usable(p_org uuid, p_customer_id uuid, p_financed_amount numeric)
RETURNS uuid LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT a.id FROM public.approvals a
    WHERE a.organization_id = p_org AND a.kind = 'credit_exception' AND a.status = 'approved'
      AND a.payload ->> 'customer_id' = p_customer_id::text AND a.entity_id IS NULL
      AND a.decided_at + app.credit_exception_ttl() >= now() AND a.amount >= p_financed_amount
    ORDER BY a.decided_at DESC, a.id LIMIT 1
$$;

-- The check N02 calls in its transaction (rule 6). Returns NULL when the sale needs no exception,
-- else the id of the exception that covers it (N02 then calls app.use_credit_approval with the
-- contract's id). Locks the customer, so two sales of one customer take turns.
CREATE FUNCTION app.check_customer_credit(p_org uuid, p_customer_id uuid, p_financed_amount numeric,
                                          p_approval_id uuid)
RETURNS uuid LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_c public.customers; v_r jsonb; v_a public.approvals;
BEGIN
    IF p_financed_amount IS NULL OR p_financed_amount <= 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: financed_amount' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_c FROM public.customers
    WHERE id = p_customer_id AND organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    v_r := app.credit_reasons(p_org, p_customer_id, p_financed_amount);
    IF jsonb_array_length(v_r -> 'reasons') = 0 THEN
        RETURN NULL;
    END IF;
    IF p_approval_id IS NULL THEN
        IF v_r -> 'reasons' ? 'limit' THEN
            RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED' USING ERRCODE = 'P0001', DETAIL = v_r::text;
        ELSIF v_r -> 'reasons' ? 'score' THEN
            RAISE EXCEPTION 'CREDIT_SCORE_TOO_LOW' USING ERRCODE = 'P0001', DETAIL = v_r::text;
        END IF;
        RAISE EXCEPTION 'CREDIT_CUSTOMER_WATCH' USING ERRCODE = 'P0001', DETAIL = v_r::text;
    END IF;
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = p_org AND a.kind = 'credit_exception'
      AND a.payload ->> 'customer_id' = p_customer_id::text FOR UPDATE;
    IF NOT FOUND OR v_a.status <> 'approved' OR v_a.entity_id IS NOT NULL
       OR v_a.decided_at + app.credit_exception_ttl() < now() OR v_a.amount < p_financed_amount THEN
        RAISE EXCEPTION 'CREDIT_APPROVAL_INVALID' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_a.id;
END;
$$;

-- N02 writes the contract's id into the exception it used: once.
CREATE FUNCTION app.use_credit_approval(p_approval_id uuid, p_contract_id uuid)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE v_a public.approvals;
BEGIN
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.kind = 'credit_exception' FOR UPDATE;
    IF NOT FOUND OR v_a.status <> 'approved' OR v_a.entity_id IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM public.contracts c
                      WHERE c.id = p_contract_id AND c.organization_id = v_a.organization_id
                        AND c.customer_id::text = v_a.payload ->> 'customer_id') THEN
        RAISE EXCEPTION 'CREDIT_APPROVAL_INVALID' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.approvals a SET entity_id = p_contract_id WHERE a.id = p_approval_id;
END;
$$;

-- The contract's CreditException (an approval of kind credit_exception).
CREATE FUNCTION app.credit_exception_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'status', a.status,
        'customer_id', (a.payload ->> 'customer_id')::uuid, 'customer_name', cu.full_name,
        'financed_amount', a.amount::numeric(18,2)::text,
        'reasons', COALESCE(a.payload -> 'reasons', '[]'::jsonb), 'reason', a.reason,
        'snapshot', jsonb_build_object('limit', a.payload ->> 'limit', 'exposure', a.payload ->> 'exposure',
            'available', a.payload ->> 'available', 'score', (a.payload ->> 'score')::integer,
            'min_score', (a.payload ->> 'min_score')::integer),
        'requested_by_name', re.full_name, 'requested_at', a.created_at,
        'mine', a.requested_by = app.current_employee_id(),
        'decided_by_name', de.full_name, 'decided_at', a.decided_at, 'decision_note', a.decision_note,
        'expires_at', CASE WHEN a.status = 'approved' THEN a.decided_at + app.credit_exception_ttl() END,
        'used', a.entity_id IS NOT NULL)
    FROM public.approvals a
    LEFT JOIN public.customers cu ON cu.id = (a.payload ->> 'customer_id')::uuid AND cu.organization_id = a.organization_id
    LEFT JOIN public.employees re ON re.id = a.requested_by AND re.organization_id = a.organization_id
    LEFT JOIN public.employees de ON de.id = a.decided_by AND de.organization_id = a.organization_id
    WHERE a.organization_id = p_org AND a.id = p_id AND a.kind = 'credit_exception'
$$;

-- 3. The safety net (rule 8) -----------------------------------------------------------------------

-- At commit a contract must fit the customer's credit: its financed amount against the limit minus
-- what the customer owed on the other contracts, unless an approved exception was used for this
-- contract. Migrated (M02) contracts are exempt. Whoever wrote the contract, even a client calling
-- the database directly, goes through this. The customer is locked first, so two contracts of one
-- customer commit one after the other and the second sees the first.
CREATE FUNCTION app.contracts_credit_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_c public.customers; v_r jsonb; v_exposure numeric;
BEGIN
    IF NEW.is_migrated THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_c FROM public.customers
    WHERE id = NEW.customer_id AND organization_id = NEW.organization_id FOR UPDATE;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    v_exposure := app.customer_exposure(NEW.organization_id, NEW.customer_id, NEW.id);
    IF NEW.financed_amount > v_c.credit_limit - v_exposure
       AND NOT EXISTS (SELECT 1 FROM public.approvals a
                       WHERE a.organization_id = NEW.organization_id AND a.kind = 'credit_exception'
                         AND a.status = 'approved' AND a.entity_id = NEW.id
                         AND a.payload ->> 'customer_id' = NEW.customer_id::text
                         AND a.amount >= NEW.financed_amount) THEN
        v_r := jsonb_build_object(
            'limit', v_c.credit_limit::numeric(18,2)::text, 'exposure', v_exposure::numeric(18,2)::text,
            'available', GREATEST(v_c.credit_limit - v_exposure, 0)::numeric(18,2)::text,
            'requested', NEW.financed_amount::numeric(18,2)::text,
            'score', app.customer_credit_score(NEW.organization_id, NEW.customer_id) -> 'score',
            'min_score', app.customer_credit_score(NEW.organization_id, NEW.customer_id) -> 'min_score',
            'reasons', jsonb_build_array('limit'));
        RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED' USING ERRCODE = 'P0001', DETAIL = v_r::text;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_contracts_credit_check
    AFTER INSERT ON public.contracts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION app.contracts_credit_check();

-- 4. Reads (rule 11: the R01 read guard, so an expired shop can still read) --------------------------

CREATE FUNCTION public.get_customer_credit_profile(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_json jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_json := app.customer_credit_profile_json(v_org, p_customer_id);
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- Would an installment sale of this financed amount pass the check now? Answers instead of raising
-- for the credit reasons; a customer who is not found, blocked or archived still raises.
CREATE FUNCTION public.get_customer_credit_check(p_customer_id uuid, p_financed_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_amount numeric; v_c public.customers; v_r jsonb; v_approved uuid; v_pending uuid;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_amount := app.parse_credit_amount(p_financed_amount, 'financed_amount', true);
    SELECT * INTO v_c FROM public.customers WHERE id = p_customer_id AND organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    v_r := app.credit_reasons(v_org, p_customer_id, v_amount);
    v_approved := app.credit_exception_usable(v_org, p_customer_id, v_amount);
    SELECT a.id INTO v_pending FROM public.approvals a
    WHERE a.organization_id = v_org AND a.kind = 'credit_exception' AND a.status = 'pending'
      AND a.payload ->> 'customer_id' = p_customer_id::text AND a.amount >= v_amount
    ORDER BY a.created_at DESC, a.id LIMIT 1;
    RETURN jsonb_build_object(
        'allowed', jsonb_array_length(v_r -> 'reasons') = 0 OR v_approved IS NOT NULL,
        'reasons', v_r -> 'reasons',
        'needs_approval', jsonb_array_length(v_r -> 'reasons') > 0 AND v_approved IS NULL,
        'limit', v_r -> 'limit', 'exposure', v_r -> 'exposure', 'available', v_r -> 'available',
        'score', v_r -> 'score', 'min_score', v_r -> 'min_score',
        'pending_approval_id', v_pending, 'approved_approval_id', v_approved);
END;
$$;

CREATE FUNCTION public.get_credit_exception(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_json jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_json := app.credit_exception_json(v_org, p_id);
    IF v_json IS NULL THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_json;
END;
$$;

-- Pending first, then newest first (at most 100).
CREATE FUNCTION public.list_credit_exceptions(p_status text DEFAULT 'pending')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_status text := COALESCE(p_status, 'pending');
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF v_status NOT IN ('pending', 'approved', 'rejected', 'cancelled', 'all') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object('items', COALESCE((
        SELECT jsonb_agg(app.credit_exception_json(v_org, k.id)
                         ORDER BY (k.status = 'pending') DESC, k.created_at DESC, k.id)
        FROM (SELECT a.id, a.status, a.created_at FROM public.approvals a
              WHERE a.organization_id = v_org AND a.kind = 'credit_exception'
                AND (v_status = 'all' OR a.status::text = v_status)
              ORDER BY (a.status = 'pending') DESC, a.created_at DESC, a.id LIMIT 100) k), '[]'::jsonb));
END;
$$;

-- 5. Writes -------------------------------------------------------------------------------------------

-- credit.approve. See rule 2. The answer is the profile.
CREATE FUNCTION public.set_customer_credit_limit(p_customer_id uuid, p_limit text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_new numeric; v_reason text; v_old public.customers;
BEGIN
    v_emp := app.require_permission('credit.approve');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_new := app.parse_credit_amount(p_limit, 'credit_limit', false);
    v_reason := NULLIF(btrim(p_reason), '');
    IF length(v_reason) > 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.customers
    WHERE id = p_customer_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_old.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED: the customer is archived' USING ERRCODE = 'P0001';
    END IF;
    IF v_new = v_old.credit_limit THEN
        RETURN app.customer_credit_profile_json(v_org, p_customer_id);
    END IF;
    IF v_new > v_old.credit_limit AND COALESCE(length(v_reason), 0) < 3 THEN
        RAISE EXCEPTION 'CREDIT_REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.customers SET credit_limit = v_new, updated_by = v_emp WHERE id = p_customer_id;
    PERFORM app.write_audit('customer.credit_limit_set', 'customer', p_customer_id,
        p_before => jsonb_build_object('credit_limit', v_old.credit_limit::numeric(18,2)::text),
        p_after => jsonb_build_object('credit_limit', v_new::numeric(18,2)::text),
        p_reason => v_reason,
        p_severity => CASE WHEN v_new > v_old.credit_limit THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.customer_credit_profile_json(v_org, p_customer_id);
END;
$$;

-- sale.create or credit.approve. The cashier asks for an exception for this customer and financed
-- amount; the server stores what it knew at that moment (limit, exposure, available, score,
-- reasons). APPROVAL_NOT_NEEDED when the sale would pass anyway; CUSTOMER_BLOCKED is never overridable.
CREATE FUNCTION public.request_credit_exception(p_customer_id uuid, p_financed_amount text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_amount numeric; v_reason text; v_c public.customers; v_r jsonb; v_id uuid;
BEGIN
    IF app.has_permission('credit.approve') THEN
        v_emp := app.require_permission('credit.approve');
    ELSE
        v_emp := app.require_permission('sale.create');
    END IF;
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_amount := app.parse_credit_amount(p_financed_amount, 'financed_amount', true);
    v_reason := NULLIF(btrim(p_reason), '');
    IF COALESCE(length(v_reason), 0) < 3 THEN
        RAISE EXCEPTION 'CREDIT_REASON_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_reason) > 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_c FROM public.customers
    WHERE id = p_customer_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    v_r := app.credit_reasons(v_org, p_customer_id, v_amount);
    IF jsonb_array_length(v_r -> 'reasons') = 0 THEN
        RAISE EXCEPTION 'APPROVAL_NOT_NEEDED' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.approvals (organization_id, kind, entity_type, amount, payload, requested_by, reason, created_by)
    VALUES (v_org, 'credit_exception', 'contract', v_amount,
            jsonb_build_object('customer_id', p_customer_id) || (v_r - 'requested'),
            v_emp, v_reason, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('credit_exception.requested', 'approval', v_id, NULL,
        jsonb_build_object('kind', 'credit_exception', 'customer_id', p_customer_id,
                           'financed_amount', v_amount::numeric(18,2)::text, 'reasons', v_r -> 'reasons'),
        v_reason);
    RETURN app.credit_exception_json(v_org, v_id);
END;
$$;

-- credit.approve. Approves or rejects a pending exception (rejecting needs a note). The requester
-- may not decide their own request, except the OWNER (D72, to confirm). Approving is refused for a
-- customer who has been blocked or archived since.
CREATE FUNCTION public.decide_credit_exception(p_approval_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_a public.approvals; v_note text; v_status public.approval_status;
    v_customer uuid; v_c public.customers;
BEGIN
    v_emp := app.require_permission('credit.approve');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p_approve IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: approve' USING ERRCODE = 'P0001';
    END IF;
    v_note := NULLIF(btrim(p_note), '');
    IF length(v_note) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    IF NOT p_approve AND COALESCE(length(v_note), 0) < 3 THEN
        RAISE EXCEPTION 'APPROVAL_NOTE_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    -- The customer first, then the approval: the same order as the check, so they never deadlock.
    SELECT (a.payload ->> 'customer_id')::uuid INTO v_customer FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'credit_exception';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_c FROM public.customers WHERE id = v_customer AND organization_id = v_org FOR UPDATE;
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'credit_exception' FOR UPDATE;
    IF v_a.status <> 'pending' THEN
        RAISE EXCEPTION 'APPROVAL_NOT_PENDING: the approval is %', v_a.status USING ERRCODE = 'P0001';
    END IF;
    IF v_a.requested_by = v_emp AND app.current_role() <> 'OWNER' THEN
        RAISE EXCEPTION 'APPROVAL_SELF' USING ERRCODE = '42501';
    END IF;
    IF p_approve AND (v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL) THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    v_status := CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
    UPDATE public.approvals a SET status = v_status, decided_by = v_emp, decided_at = now(), decision_note = v_note
    WHERE a.id = p_approval_id;
    PERFORM app.write_audit(CASE WHEN p_approve THEN 'credit_exception.approved' ELSE 'credit_exception.rejected' END,
        'approval', p_approval_id,
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('kind', 'credit_exception', 'status', v_status, 'customer_id', v_customer,
                           'financed_amount', v_a.amount::numeric(18,2)::text, 'requested_by', v_a.requested_by),
        v_note, NULL,
        CASE WHEN p_approve THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.credit_exception_json(v_org, p_approval_id);
END;
$$;

-- The requester takes the request back while it is pending.
CREATE FUNCTION public.cancel_credit_exception(p_approval_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_a public.approvals;
BEGIN
    IF app.has_permission('credit.approve') THEN
        v_emp := app.require_permission('credit.approve');
    ELSE
        v_emp := app.require_permission('sale.create');
    END IF;
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    SELECT * INTO v_a FROM public.approvals a
    WHERE a.id = p_approval_id AND a.organization_id = v_org AND a.kind = 'credit_exception'
      AND a.requested_by = v_emp FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'APPROVAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_a.status <> 'pending' THEN
        RAISE EXCEPTION 'APPROVAL_NOT_PENDING: the approval is %', v_a.status USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.approvals a SET status = 'cancelled' WHERE a.id = p_approval_id;
    PERFORM app.write_audit('credit_exception.cancelled', 'approval', p_approval_id,
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('kind', 'credit_exception', 'status', 'cancelled',
                           'customer_id', v_a.payload ->> 'customer_id'));
    RETURN app.credit_exception_json(v_org, p_approval_id);
END;
$$;

-- 6. Grants: the eight public functions only ------------------------------------------------------------

REVOKE ALL ON FUNCTION app.approvals_freeze(), app.credit_exception_ttl(),
    app.parse_credit_amount(text, text, boolean), app.customer_exposure(uuid, uuid, uuid),
    app.customer_suggested_limit(uuid, uuid), app.customer_credit_score(uuid, uuid),
    app.customer_credit_behaviour(uuid, uuid), app.customer_credit_profile_json(uuid, uuid),
    app.credit_reasons(uuid, uuid, numeric), app.credit_exception_usable(uuid, uuid, numeric),
    app.check_customer_credit(uuid, uuid, numeric, uuid), app.use_credit_approval(uuid, uuid),
    app.credit_exception_json(uuid, uuid), app.contracts_credit_check()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_customer_credit_profile(uuid), public.get_customer_credit_check(uuid, text),
    public.get_credit_exception(uuid), public.list_credit_exceptions(text),
    public.set_customer_credit_limit(uuid, text, text), public.request_credit_exception(uuid, text, text),
    public.decide_credit_exception(uuid, boolean, text), public.cancel_credit_exception(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_credit_profile(uuid), public.get_customer_credit_check(uuid, text),
    public.get_credit_exception(uuid), public.list_credit_exceptions(text),
    public.set_customer_credit_limit(uuid, text, text), public.request_credit_exception(uuid, text, text),
    public.decide_credit_exception(uuid, boolean, text), public.cancel_credit_exception(uuid)
    TO authenticated;
