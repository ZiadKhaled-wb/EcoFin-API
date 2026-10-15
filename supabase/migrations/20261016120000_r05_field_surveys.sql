-- =============================================================================
-- R05 · Field surveys (EC-67, D75)
--
-- Before the shop lends its own money above a set amount, someone visits the customer's home or
-- work. A manager assigns the visit to an employee (often a collector); the assignee fills a
-- checklist, scores six criteria, writes notes, captures the GPS fix and uploads photos (F14,
-- private), then submits; a manager approves or rejects. The latest approved survey of the last
-- 180 days fills the residence part of the R03 credit score. The installment policy's
-- survey_required_above says above which financed amount a contract needs such a survey; the
-- contract-side rule is a database function plus a commit-time trigger (as R04), so the server
-- refuses a contract without an approved survey even when the client calls the database directly.
--
-- Numbered after the newest migration on main (D39). Everything below is NEW except:
--   * field_surveys gets seven columns (visit_type, checklist, due_date, instructions,
--     survey_score, decision_note, client_captured_at); the baseline's RLS, updated_at, no-delete
--     and freeze (approved / rejected / cancelled) triggers stay as they are;
--   * public.register_file is re-created from its latest version (R04) with the entity type
--     'field_survey' and its rules (assignee only, status assigned, at most 10 photos);
--   * app.customer_credit_score (R03) is re-created with the residence line filled from the survey;
--   * app.customer_credit_profile_json (R03) is re-created with the key latest_survey.
--
-- Rules (D75):
--   1. Flow: assigned -> submitted -> approved | rejected; cancelled from assigned or submitted.
--   2. Six criteria 1-10 (scores) and six yes/no checklist items, all required on submit; the
--      survey score = round(average x 10), 0-100, written on submit.
--   3. GPS on submit: lat, lng, accuracy (m) and the phone's capture time (at most 5 minutes in the
--      future, not more than 5 minutes before the survey was created). Accuracy above 100 m is
--      flagged to the reviewer, never refused.
--   4. Photos = F14 files, purpose survey_photo, entity type field_survey: only the assignee, while
--      assigned, at most 10; submit needs at least 1. Reading them keeps the key customer.view_pii.
--   5. Assign, reassign, cancel: survey.assign. Save, submit: survey.submit and be the assignee.
--      Decide: survey.decide, not the assignee unless the OWNER. Reads: the R01 read guard; a caller
--      with survey.submit but neither survey.assign nor survey.decide sees only their own surveys.
--   6. One open survey (assigned or submitted) per customer; the customer must be active or watch;
--      the assignee an active employee of the shop with survey.submit.
--   7. A survey is valid for 180 days after its approval. A contract whose financed amount is
--      greater than the policy's survey_required_above needs a valid approved survey of its
--      customer (app.check_contract_survey; trg_contracts_survey_check at commit; migrated
--      contracts are exempt).
-- =============================================================================

-- 1. The columns -----------------------------------------------------------------------------------

ALTER TABLE public.field_surveys
    ADD COLUMN visit_type         text NOT NULL DEFAULT 'home' CHECK (visit_type IN ('home', 'work')),
    ADD COLUMN checklist          jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN due_date           date,
    ADD COLUMN instructions       text CHECK (length(instructions) <= 500),
    ADD COLUMN survey_score       smallint CHECK (survey_score BETWEEN 0 AND 100),
    ADD COLUMN decision_note      text CHECK (length(decision_note) <= 500),
    ADD COLUMN client_captured_at timestamptz;

-- 2. Helpers (no grants) -----------------------------------------------------------------------------

CREATE FUNCTION app.survey_valid_days()
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$ SELECT 180 $$;

CREATE FUNCTION app.survey_criteria()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT ARRAY['housing_quality', 'neighbourhood', 'income_stability', 'job_status',
                 'property_ownership', 'overall_impression']
$$;

CREATE FUNCTION app.survey_checklist_items()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT ARRAY['met_customer', 'address_matches', 'id_original_seen', 'neighbours_confirm',
                 'utility_bill_seen', 'workplace_confirmed']
$$;

-- An employee of the shop, active, who holds the key (role default + override; OWNER has all).
CREATE FUNCTION app.employee_can(p_org uuid, p_employee_id uuid, p_key text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT COALESCE((
        SELECT CASE
            WHEN e.role = 'OWNER' THEN true
            ELSE COALESCE(
                (SELECT o.granted FROM public.employee_permission_overrides o
                 WHERE o.employee_id = e.id AND o.permission_key = p_key),
                EXISTS (SELECT 1 FROM public.role_permissions rp
                        WHERE rp.role = e.role AND rp.permission_key = p_key))
        END
        FROM public.employees e
        WHERE e.id = p_employee_id AND e.organization_id = p_org
          AND e.is_active AND e.archived_at IS NULL), false)
$$;

-- Rule 5: true when the caller sees every survey of the shop, false when only their own.
CREATE FUNCTION app.survey_sees_all()
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT app.has_permission('survey.assign') OR app.has_permission('survey.decide')
        OR NOT app.has_permission('survey.submit')
$$;

-- The last day an approved survey counts (the shop's calendar), NULL when not approved.
CREATE FUNCTION app.survey_valid_until(p_org uuid, s public.field_surveys)
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE WHEN s.status = 'approved' AND s.decided_at IS NOT NULL THEN
        ((s.decided_at + make_interval(days => app.survey_valid_days())) AT TIME ZONE o.timezone)::date END
    FROM public.organizations o WHERE o.id = p_org
$$;

-- Row shape of the contract's Survey.
CREATE FUNCTION app.field_survey_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', s.id, 'status', s.status, 'visit_type', s.visit_type,
        'customer', jsonb_build_object('id', c.id, 'full_name', c.full_name, 'phones', to_jsonb(c.phones),
                                       'address', c.address, 'city', c.city),
        'assigned_to', jsonb_build_object('id', a.id, 'full_name', a.full_name),
        'instructions', s.instructions, 'due_date', s.due_date,
        'scores', s.scores, 'checklist', s.checklist, 'notes', s.notes,
        'gps', CASE WHEN s.lat IS NOT NULL THEN jsonb_build_object(
                   'lat', s.lat, 'lng', s.lng, 'gps_accuracy_m', s.gps_accuracy_m,
                   'client_captured_at', s.client_captured_at) END,
        'gps_low_accuracy', COALESCE(s.gps_accuracy_m > 100, false),
        'survey_score', s.survey_score,
        'photos_count', (SELECT count(*) FROM public.files f
                         WHERE f.organization_id = p_org AND f.entity_type = 'field_survey'
                           AND f.entity_id = s.id AND f.purpose = 'survey_photo'),
        'submitted_at', s.submitted_at,
        'decided_by', CASE WHEN d.id IS NOT NULL THEN jsonb_build_object('id', d.id, 'full_name', d.full_name) END,
        'decided_at', s.decided_at, 'decision_note', s.decision_note,
        'valid_until', app.survey_valid_until(p_org, s),
        'created_by', CASE WHEN b.id IS NOT NULL THEN jsonb_build_object('id', b.id, 'full_name', b.full_name) END,
        'created_at', s.created_at, 'updated_at', s.updated_at)
    FROM public.field_surveys s
    JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = s.organization_id
    JOIN public.employees a ON a.id = s.assigned_to AND a.organization_id = s.organization_id
    LEFT JOIN public.employees d ON d.id = s.decided_by AND d.organization_id = s.organization_id
    LEFT JOIN public.employees b ON b.id = s.created_by AND b.organization_id = s.organization_id
    WHERE s.id = p_id AND s.organization_id = p_org
$$;

-- Validates a scores object and merges it into p_old: each value an integer 1-10 or null (null
-- removes the key). p_complete: every criterion must be there afterwards.
CREATE FUNCTION app.survey_merge_scores(p_old jsonb, p_new jsonb, p_complete boolean)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_key text; v_out jsonb := COALESCE(p_old, '{}'::jsonb);
BEGIN
    IF p_new IS NOT NULL THEN
        IF jsonb_typeof(p_new) <> 'object' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: scores' USING ERRCODE = 'P0001';
        END IF;
        FOR v_key IN SELECT jsonb_object_keys(p_new) LOOP
            IF v_key <> ALL (app.survey_criteria()) THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: scores' USING ERRCODE = 'P0001';
            END IF;
            IF jsonb_typeof(p_new -> v_key) = 'null' THEN
                v_out := v_out - v_key;
            ELSIF jsonb_typeof(p_new -> v_key) <> 'number' OR (p_new ->> v_key) !~ '^([1-9]|10)$' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: scores' USING ERRCODE = 'P0001';
            ELSE
                v_out := v_out || jsonb_build_object(v_key, (p_new ->> v_key)::integer);
            END IF;
        END LOOP;
    END IF;
    IF p_complete AND EXISTS (SELECT 1 FROM unnest(app.survey_criteria()) k WHERE NOT v_out ? k) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: scores' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_out;
END;
$$;

-- The same for the checklist: each value true, false or null (removes the key).
CREATE FUNCTION app.survey_merge_checklist(p_old jsonb, p_new jsonb, p_complete boolean)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $$
DECLARE v_key text; v_out jsonb := COALESCE(p_old, '{}'::jsonb);
BEGIN
    IF p_new IS NOT NULL THEN
        IF jsonb_typeof(p_new) <> 'object' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: checklist' USING ERRCODE = 'P0001';
        END IF;
        FOR v_key IN SELECT jsonb_object_keys(p_new) LOOP
            IF v_key <> ALL (app.survey_checklist_items()) THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: checklist' USING ERRCODE = 'P0001';
            END IF;
            IF jsonb_typeof(p_new -> v_key) = 'null' THEN
                v_out := v_out - v_key;
            ELSIF jsonb_typeof(p_new -> v_key) <> 'boolean' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: checklist' USING ERRCODE = 'P0001';
            ELSE
                v_out := v_out || jsonb_build_object(v_key, p_new -> v_key);
            END IF;
        END LOOP;
    END IF;
    IF p_complete AND EXISTS (SELECT 1 FROM unnest(app.survey_checklist_items()) k WHERE NOT v_out ? k) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: checklist' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_out;
END;
$$;

-- Applies the answer keys of c (visit_type, scores, checklist, notes, gps) to the row r and
-- validates them. A key that is not sent keeps its value; notes null or '' clears; gps null clears.
CREATE FUNCTION app.survey_apply_answers(r public.field_surveys, c jsonb)
RETURNS public.field_surveys LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_key text; v_txt text; v_gps jsonb; v_at timestamptz;
BEGIN
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (ARRAY['visit_type', 'scores', 'checklist', 'notes', 'gps']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    IF c ? 'visit_type' THEN
        IF jsonb_typeof(c -> 'visit_type') <> 'string' OR (c ->> 'visit_type') NOT IN ('home', 'work') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: visit_type' USING ERRCODE = 'P0001';
        END IF;
        r.visit_type := c ->> 'visit_type';
    END IF;
    IF c ? 'scores' THEN
        r.scores := app.survey_merge_scores(r.scores, c -> 'scores', false);
    END IF;
    IF c ? 'checklist' THEN
        r.checklist := app.survey_merge_checklist(r.checklist, c -> 'checklist', false);
    END IF;
    IF c ? 'notes' THEN
        IF jsonb_typeof(c -> 'notes') NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
        END IF;
        v_txt := NULLIF(btrim(c ->> 'notes'), '');
        IF length(v_txt) > 2000 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
        END IF;
        r.notes := v_txt;
    END IF;
    IF c ? 'gps' THEN
        v_gps := c -> 'gps';
        IF jsonb_typeof(v_gps) = 'null' THEN
            r.lat := NULL; r.lng := NULL; r.gps_accuracy_m := NULL; r.client_captured_at := NULL;
        ELSE
            IF jsonb_typeof(v_gps) <> 'object'
               OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_gps) k)
                  IS DISTINCT FROM ARRAY['client_captured_at', 'gps_accuracy_m', 'lat', 'lng']
               OR jsonb_typeof(v_gps -> 'lat') <> 'number' OR jsonb_typeof(v_gps -> 'lng') <> 'number'
               OR jsonb_typeof(v_gps -> 'gps_accuracy_m') <> 'number'
               OR jsonb_typeof(v_gps -> 'client_captured_at') <> 'string' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: gps' USING ERRCODE = 'P0001';
            END IF;
            BEGIN
                v_at := (v_gps ->> 'client_captured_at')::timestamptz;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: gps' USING ERRCODE = 'P0001';
            END;
            IF (v_gps ->> 'lat')::numeric NOT BETWEEN -90 AND 90
               OR (v_gps ->> 'lng')::numeric NOT BETWEEN -180 AND 180
               OR (v_gps ->> 'gps_accuracy_m')::numeric < 0
               OR (v_gps ->> 'gps_accuracy_m')::numeric >= 1000000
               OR v_at > now() + interval '5 minutes'
               OR v_at < r.created_at - interval '5 minutes' THEN
                RAISE EXCEPTION 'VALIDATION_FAILED: gps' USING ERRCODE = 'P0001';
            END IF;
            r.lat := round((v_gps ->> 'lat')::numeric, 6);
            r.lng := round((v_gps ->> 'lng')::numeric, 6);
            r.gps_accuracy_m := round((v_gps ->> 'gps_accuracy_m')::numeric, 2);
            r.client_captured_at := v_at;
        END IF;
    END IF;
    RETURN r;
END;
$$;

-- The answer fields (the audit before/after of a save). The GPS point is shown as present / absent.
CREATE FUNCTION app.survey_answers_json(r public.field_surveys)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('visit_type', r.visit_type, 'scores', r.scores, 'checklist', r.checklist,
                              'notes', r.notes,
                              'gps', CASE WHEN r.lat IS NOT NULL THEN jsonb_build_object(
                                         'gps_accuracy_m', r.gps_accuracy_m,
                                         'client_captured_at', r.client_captured_at) END)
$$;

-- The survey of this shop the caller may see, locked when p_lock. SURVEY_NOT_FOUND otherwise
-- (a collector asking for another collector's survey gets the same answer).
CREATE FUNCTION app.survey_for_caller(p_org uuid, p_id uuid, p_lock boolean)
RETURNS public.field_surveys LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE r public.field_surveys;
BEGIN
    IF p_lock THEN
        SELECT * INTO r FROM public.field_surveys WHERE id = p_id AND organization_id = p_org FOR UPDATE;
    ELSE
        SELECT * INTO r FROM public.field_surveys WHERE id = p_id AND organization_id = p_org;
    END IF;
    IF NOT FOUND OR (NOT app.survey_sees_all() AND r.assigned_to IS DISTINCT FROM app.current_employee_id()) THEN
        RAISE EXCEPTION 'SURVEY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN r;
END;
$$;

-- Rule 6: the assignee must be an active employee of the shop with survey.submit.
CREATE FUNCTION app.survey_check_assignee(p_org uuid, p_employee_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
BEGIN
    IF p_employee_id IS NULL OR NOT app.employee_can(p_org, p_employee_id, 'survey.submit') THEN
        RAISE EXCEPTION 'SURVEY_ASSIGNEE_INVALID' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('employee_id', p_employee_id)::text;
    END IF;
END;
$$;

-- 3. Contract rule (rule 7; for N01/N02, no route of their own) -----------------------------------

-- Does a contract of this policy version and financed amount need a survey?
CREATE FUNCTION app.survey_required(p_org uuid, p_policy_id uuid, p_financed_amount numeric)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT COALESCE((
        SELECT p.survey_required_above IS NOT NULL AND p_financed_amount > p.survey_required_above
        FROM public.installment_policies p
        WHERE p.id = p_policy_id AND p.organization_id = p_org), false)
$$;

-- The newest approved survey of the customer decided within the validity days, or NULL.
CREATE FUNCTION app.latest_valid_survey(p_org uuid, p_customer_id uuid)
RETURNS uuid LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT s.id FROM public.field_surveys s
    WHERE s.organization_id = p_org AND s.customer_id = p_customer_id AND s.status = 'approved'
      AND s.decided_at > now() - make_interval(days => app.survey_valid_days())
    ORDER BY s.decided_at DESC, s.id DESC LIMIT 1
$$;

-- Returns the survey that allows the contract (NULL when none is needed); raises SURVEY_REQUIRED
-- with {required_above, financed_amount, open_survey_id, open_status, last_decided_status}.
CREATE FUNCTION app.check_contract_survey(p_org uuid, p_customer_id uuid, p_policy_id uuid,
                                          p_financed_amount numeric)
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE v_id uuid; v_open public.field_surveys; v_last public.survey_status;
BEGIN
    IF NOT app.survey_required(p_org, p_policy_id, p_financed_amount) THEN
        RETURN NULL;
    END IF;
    v_id := app.latest_valid_survey(p_org, p_customer_id);
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;
    SELECT * INTO v_open FROM public.field_surveys s
    WHERE s.organization_id = p_org AND s.customer_id = p_customer_id AND s.status IN ('assigned', 'submitted')
    ORDER BY s.created_at DESC, s.id DESC LIMIT 1;
    SELECT s.status INTO v_last FROM public.field_surveys s
    WHERE s.organization_id = p_org AND s.customer_id = p_customer_id AND s.status IN ('approved', 'rejected')
    ORDER BY s.decided_at DESC, s.id DESC LIMIT 1;
    RAISE EXCEPTION 'SURVEY_REQUIRED' USING ERRCODE = 'P0001',
        DETAIL = jsonb_build_object(
            'required_above', (SELECT p.survey_required_above::numeric(18,2)::text FROM public.installment_policies p
                               WHERE p.id = p_policy_id AND p.organization_id = p_org),
            'financed_amount', p_financed_amount::numeric(18,2)::text,
            'open_survey_id', v_open.id, 'open_status', v_open.status,
            'last_decided_status', v_last)::text;
END;
$$;

-- The safety net: at commit a contract that needs a survey must have a valid approved one,
-- whoever wrote it. Migrated (M02) contracts are exempt.
CREATE FUNCTION app.contracts_survey_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NEW.is_migrated THEN
        RETURN NULL;
    END IF;
    PERFORM app.check_contract_survey(NEW.organization_id, NEW.customer_id, NEW.policy_id, NEW.financed_amount);
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_contracts_survey_check
    AFTER INSERT ON public.contracts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION app.contracts_survey_check();

-- 4. R03: the residence part of the score and the latest survey on the profile ----------------------

-- Re-created from R03; the only change: residence = the latest valid approved survey's score / 100.
CREATE OR REPLACE FUNCTION app.customer_credit_score(p_org uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path = ''
AS $$
DECLARE
    v_c public.customers; v_s public.org_settings; v_guarantors integer; v_photos integer;
    v_id_ok boolean; v_comp jsonb; v_total numeric; v_residence numeric;
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
    v_residence := COALESCE((SELECT s.survey_score / 100.0 FROM public.field_surveys s
                             WHERE s.id = app.latest_valid_survey(p_org, p_customer_id)
                               AND s.organization_id = p_org), 0.0);

    WITH c(ord, key, value) AS (VALUES
        (1, 'guarantors', LEAST(v_guarantors / 2.0, 1.0)),
        (2, 'income',     CASE WHEN COALESCE(v_c.monthly_income, 0) > 0 THEN 1.0 ELSE 0.0 END),
        (3, 'residence',  v_residence),
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

-- Re-created from R03; the only change: the key latest_survey (the newest survey, any status).
CREATE OR REPLACE FUNCTION app.customer_credit_profile_json(p_org uuid, p_customer_id uuid)
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
            LEFT JOIN public.employees e ON e.id = h.employee_id AND e.organization_id = h.organization_id), '[]'::jsonb),
        'latest_survey', (
            SELECT jsonb_build_object('id', s.id, 'status', s.status, 'survey_score', s.survey_score,
                                      'decided_at', s.decided_at, 'valid_until', app.survey_valid_until(p_org, s))
            FROM public.field_surveys s
            WHERE s.organization_id = p_org AND s.customer_id = p_customer_id
            ORDER BY s.created_at DESC, s.id DESC LIMIT 1));
END;
$$;

REVOKE ALL ON FUNCTION app.survey_valid_days(), app.survey_criteria(), app.survey_checklist_items(),
    app.employee_can(uuid, uuid, text), app.survey_sees_all(),
    app.survey_valid_until(uuid, public.field_surveys), app.field_survey_json(uuid, uuid),
    app.survey_merge_scores(jsonb, jsonb, boolean), app.survey_merge_checklist(jsonb, jsonb, boolean),
    app.survey_apply_answers(public.field_surveys, jsonb), app.survey_answers_json(public.field_surveys),
    app.survey_for_caller(uuid, uuid, boolean), app.survey_check_assignee(uuid, uuid),
    app.survey_required(uuid, uuid, numeric), app.latest_valid_survey(uuid, uuid),
    app.check_contract_survey(uuid, uuid, uuid, numeric), app.contracts_survey_check()
    FROM PUBLIC, anon, authenticated;

-- 5. Reads (rule 5) -------------------------------------------------------------------------------

-- Newest first; with no status filter the submitted ones (the review queue) come first.
CREATE FUNCTION public.list_field_surveys(p_status text DEFAULT NULL, p_customer_id uuid DEFAULT NULL,
                                          p_assigned_to uuid DEFAULT NULL, p_mine boolean DEFAULT false,
                                          p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_emp uuid; v_own boolean; v_status public.survey_status; v_result jsonb;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    v_emp := app.current_employee_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_status IS NOT NULL THEN
        IF p_status <> ALL (enum_range(NULL::public.survey_status)::text[]) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
        END IF;
        v_status := p_status::public.survey_status;
    END IF;
    v_own := COALESCE(p_mine, false) OR NOT app.survey_sees_all();

    WITH found AS (
        SELECT s.id, s.status, s.created_at FROM public.field_surveys s
        WHERE s.organization_id = v_org
          AND (v_status IS NULL OR s.status = v_status)
          AND (p_customer_id IS NULL OR s.customer_id = p_customer_id)
          AND (p_assigned_to IS NULL OR s.assigned_to = p_assigned_to)
          AND (NOT v_own OR s.assigned_to = v_emp)
    ), page AS (
        SELECT f.*, row_number() OVER (ORDER BY (v_status IS NULL AND f.status = 'submitted') DESC,
                                                f.created_at DESC, f.id DESC) AS rn
        FROM found f
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.field_survey_json(v_org, p.id) ORDER BY p.rn)
            FROM page p WHERE p.rn > p_offset AND p.rn <= p_offset + p_limit), '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_field_survey(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; r public.field_surveys;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    r := app.survey_for_caller(v_org, p_id, false);
    RETURN app.field_survey_json(v_org, r.id);
END;
$$;

-- The customer's surveys, newest first (at most 50); a collector sees only their own.
CREATE FUNCTION public.list_customer_surveys(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_all boolean;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_all := app.survey_sees_all();
    RETURN COALESCE((
        SELECT jsonb_agg(app.field_survey_json(v_org, x.id) ORDER BY x.created_at DESC, x.id DESC)
        FROM (SELECT s.id, s.created_at FROM public.field_surveys s
              WHERE s.organization_id = v_org AND s.customer_id = p_customer_id
                AND (v_all OR s.assigned_to = app.current_employee_id())
              ORDER BY s.created_at DESC, s.id DESC LIMIT 50) x), '[]'::jsonb);
END;
$$;

-- Does this customer meet the shop's current policy for a financed amount (cash price - down payment)?
CREATE FUNCTION public.get_survey_requirement(p_customer_id uuid, p_financed_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_policy public.installment_policies; v_required boolean; v_valid uuid;
        v_open public.field_surveys; v_s public.field_surveys;
BEGIN
    PERFORM app.customer_read_guard();
    v_org := app.current_org_id();
    IF p_financed_amount IS NULL OR p_financed_amount !~ '^[0-9]{1,16}(\.[0-9]{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: financed_amount' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id AND organization_id = v_org) THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    v_policy := app.current_installment_policy(v_org);
    v_required := v_policy.id IS NOT NULL
                  AND app.survey_required(v_org, v_policy.id, p_financed_amount::numeric);
    v_valid := app.latest_valid_survey(v_org, p_customer_id);
    SELECT * INTO v_s FROM public.field_surveys WHERE id = v_valid AND organization_id = v_org;
    SELECT * INTO v_open FROM public.field_surveys s
    WHERE s.organization_id = v_org AND s.customer_id = p_customer_id AND s.status IN ('assigned', 'submitted')
    ORDER BY s.created_at DESC, s.id DESC LIMIT 1;
    RETURN jsonb_build_object(
        'policy_id', v_policy.id, 'policy_version', v_policy.version,
        'required_above', v_policy.survey_required_above::numeric(18,2)::text,
        'required', v_required,
        'valid_survey', CASE WHEN v_s.id IS NOT NULL THEN jsonb_build_object(
            'id', v_s.id, 'survey_score', v_s.survey_score, 'decided_at', v_s.decided_at,
            'valid_until', app.survey_valid_until(v_org, v_s)) END,
        'open_survey', CASE WHEN v_open.id IS NOT NULL THEN jsonb_build_object(
            'id', v_open.id, 'status', v_open.status) END,
        'met', NOT v_required OR v_valid IS NOT NULL);
END;
$$;

-- 6. Writes -------------------------------------------------------------------------------------

-- survey.assign. Body {customer_id, assigned_to, visit_type?, due_date?, instructions?}. The
-- customer row is locked so two managers can't open two surveys for one customer at once.
CREATE FUNCTION public.assign_field_survey(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_key text; v_customer uuid; v_assignee uuid; v_c public.customers;
    v_visit text := 'home'; v_due date; v_instr text; v_open public.field_surveys; v_id uuid;
BEGIN
    v_emp := app.require_permission('survey.assign');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_body) k
    WHERE k <> ALL (ARRAY['customer_id', 'assigned_to', 'visit_type', 'due_date', 'instructions']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'customer_id') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: customer_id' USING ERRCODE = 'P0001';
    END IF;
    IF jsonb_typeof(p_body -> 'assigned_to') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: assigned_to' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        v_customer := (p_body ->> 'customer_id')::uuid;
        v_assignee := (p_body ->> 'assigned_to')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: id' USING ERRCODE = 'P0001';
    END;
    IF p_body ? 'visit_type' THEN
        IF jsonb_typeof(p_body -> 'visit_type') <> 'string' OR (p_body ->> 'visit_type') NOT IN ('home', 'work') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: visit_type' USING ERRCODE = 'P0001';
        END IF;
        v_visit := p_body ->> 'visit_type';
    END IF;
    IF p_body ? 'due_date' AND jsonb_typeof(p_body -> 'due_date') <> 'null' THEN
        IF jsonb_typeof(p_body -> 'due_date') <> 'string' OR (p_body ->> 'due_date') !~ '^\d{4}-\d{2}-\d{2}$' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: due_date' USING ERRCODE = 'P0001';
        END IF;
        BEGIN
            v_due := (p_body ->> 'due_date')::date;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: due_date' USING ERRCODE = 'P0001';
        END;
        IF v_due < app.org_today(v_org) THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: due_date' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    IF p_body ? 'instructions' THEN
        IF jsonb_typeof(p_body -> 'instructions') NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: instructions' USING ERRCODE = 'P0001';
        END IF;
        v_instr := NULLIF(btrim(p_body ->> 'instructions'), '');
        IF length(v_instr) > 500 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: instructions' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    SELECT * INTO v_c FROM public.customers WHERE id = v_customer AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_c.status = 'blocked' OR v_c.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BLOCKED' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.survey_check_assignee(v_org, v_assignee);
    SELECT * INTO v_open FROM public.field_surveys s
    WHERE s.organization_id = v_org AND s.customer_id = v_customer AND s.status IN ('assigned', 'submitted')
    ORDER BY s.created_at DESC LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'SURVEY_ALREADY_OPEN' USING ERRCODE = 'P0001',
            DETAIL = jsonb_build_object('survey_id', v_open.id, 'status', v_open.status)::text;
    END IF;

    INSERT INTO public.field_surveys (organization_id, customer_id, assigned_to, visit_type, due_date,
                                      instructions, created_by, updated_by)
    VALUES (v_org, v_customer, v_assignee, v_visit, v_due, v_instr, v_emp, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('survey.assigned', 'field_survey', v_id,
        p_after => jsonb_build_object('customer_id', v_customer, 'assigned_to', v_assignee,
                                      'visit_type', v_visit, 'due_date', v_due));
    RETURN app.field_survey_json(v_org, v_id);
END;
$$;

-- survey.assign; status assigned only. Answers and photos saved so far stay.
CREATE FUNCTION public.reassign_field_survey(p_id uuid, p_assigned_to uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; r public.field_surveys;
BEGIN
    v_emp := app.require_permission('survey.assign');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    r := app.survey_for_caller(v_org, p_id, true);
    IF r.status <> 'assigned' THEN
        RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.survey_check_assignee(v_org, p_assigned_to);
    IF r.assigned_to = p_assigned_to THEN
        RETURN app.field_survey_json(v_org, p_id);          -- no change, no audit row
    END IF;
    UPDATE public.field_surveys SET assigned_to = p_assigned_to, updated_by = v_emp WHERE id = p_id;
    PERFORM app.write_audit('survey.reassigned', 'field_survey', p_id,
        jsonb_build_object('assigned_to', r.assigned_to), jsonb_build_object('assigned_to', p_assigned_to));
    RETURN app.field_survey_json(v_org, p_id);
END;
$$;

-- survey.assign; from assigned or submitted; a reason of 3-300 (kept in decision_note).
CREATE FUNCTION public.cancel_field_survey(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; r public.field_surveys; v_reason text := btrim(p_reason);
BEGIN
    v_emp := app.require_permission('survey.assign');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF v_reason IS NULL OR length(v_reason) < 3 OR length(v_reason) > 300 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: reason' USING ERRCODE = 'P0001';
    END IF;
    r := app.survey_for_caller(v_org, p_id, true);
    IF r.status NOT IN ('assigned', 'submitted') THEN
        RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.field_surveys SET status = 'cancelled', decision_note = v_reason, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit('survey.cancelled', 'field_survey', p_id,
        jsonb_build_object('status', r.status), jsonb_build_object('status', 'cancelled'),
        v_reason, NULL, 'warning');
    RETURN app.field_survey_json(v_org, p_id);
END;
$$;

-- survey.submit and the assignee; status assigned. Merges the answers; the same values again write
-- nothing.
CREATE FUNCTION public.save_field_survey(p_id uuid, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.field_surveys; r public.field_surveys;
    v_old_json jsonb; v_new_json jsonb; v_before jsonb; v_after jsonb;
BEGIN
    v_emp := app.require_permission('survey.submit');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_old := app.survey_for_caller(v_org, p_id, true);
    IF v_old.assigned_to <> v_emp THEN
        RAISE EXCEPTION 'SURVEY_NOT_ASSIGNEE' USING ERRCODE = 'P0001';
    END IF;
    IF v_old.status <> 'assigned' THEN
        RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
    END IF;
    IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' OR p_body = '{}'::jsonb THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    r := app.survey_apply_answers(v_old, p_body);
    v_old_json := app.survey_answers_json(v_old);
    v_new_json := app.survey_answers_json(r);
    IF v_new_json = v_old_json AND r.lat IS NOT DISTINCT FROM v_old.lat AND r.lng IS NOT DISTINCT FROM v_old.lng THEN
        RETURN app.field_survey_json(v_org, p_id);
    END IF;
    UPDATE public.field_surveys SET
        visit_type = r.visit_type, scores = r.scores, checklist = r.checklist, notes = r.notes,
        lat = r.lat, lng = r.lng, gps_accuracy_m = r.gps_accuracy_m, client_captured_at = r.client_captured_at,
        updated_by = v_emp
    WHERE id = p_id;
    SELECT COALESCE(jsonb_object_agg(k, v_old_json -> k), '{}'::jsonb),
           COALESCE(jsonb_object_agg(k, v_new_json -> k), '{}'::jsonb)
    INTO v_before, v_after
    FROM jsonb_object_keys(v_new_json) k
    WHERE (v_old_json -> k) IS DISTINCT FROM (v_new_json -> k)
       OR (k = 'gps' AND (r.lat IS DISTINCT FROM v_old.lat OR r.lng IS DISTINCT FROM v_old.lng));
    PERFORM app.write_audit('survey.saved', 'field_survey', p_id, v_before, v_after);
    RETURN app.field_survey_json(v_org, p_id);
END;
$$;

-- survey.submit and the assignee; status assigned. Applies the body (may be empty), then every
-- criterion, checklist item, the GPS fix and at least one photo are required.
CREATE FUNCTION public.submit_field_survey(p_id uuid, p_body jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_old public.field_surveys; r public.field_surveys; v_score integer;
BEGIN
    v_emp := app.require_permission('survey.submit');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    v_old := app.survey_for_caller(v_org, p_id, true);
    IF v_old.assigned_to <> v_emp THEN
        RAISE EXCEPTION 'SURVEY_NOT_ASSIGNEE' USING ERRCODE = 'P0001';
    END IF;
    IF v_old.status <> 'assigned' THEN
        RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
    END IF;
    r := app.survey_apply_answers(v_old, COALESCE(p_body, '{}'::jsonb));
    r.scores := app.survey_merge_scores(r.scores, NULL, true);
    r.checklist := app.survey_merge_checklist(r.checklist, NULL, true);
    IF r.lat IS NULL OR r.lng IS NULL OR r.gps_accuracy_m IS NULL OR r.client_captured_at IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: gps' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.files f
                   WHERE f.organization_id = v_org AND f.entity_type = 'field_survey'
                     AND f.entity_id = p_id AND f.purpose = 'survey_photo') THEN
        RAISE EXCEPTION 'SURVEY_PHOTO_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    SELECT round(avg(v::integer) * 10)::integer INTO v_score
    FROM jsonb_each_text(r.scores) AS e(k, v);
    UPDATE public.field_surveys SET
        visit_type = r.visit_type, scores = r.scores, checklist = r.checklist, notes = r.notes,
        lat = r.lat, lng = r.lng, gps_accuracy_m = r.gps_accuracy_m, client_captured_at = r.client_captured_at,
        survey_score = v_score, submitted_at = now(), status = 'submitted', updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit('survey.submitted', 'field_survey', p_id,
        jsonb_build_object('status', 'assigned'),
        jsonb_build_object('status', 'submitted', 'survey_score', v_score,
                           'gps_accuracy_m', r.gps_accuracy_m));
    RETURN app.field_survey_json(v_org, p_id);
END;
$$;

-- survey.decide; status submitted. The assignee can't decide their own survey unless the OWNER.
-- A rejection needs a note (3-500); an approval may have one.
CREATE FUNCTION public.decide_field_survey(p_id uuid, p_decision text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; r public.field_surveys; v_note text := NULLIF(btrim(p_note), '');
        v_status public.survey_status;
BEGIN
    v_emp := app.require_permission('survey.decide');
    PERFORM app.require_module('customers');
    v_org := app.current_org_id();
    IF p_decision IS NULL OR p_decision NOT IN ('approve', 'reject') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: decision' USING ERRCODE = 'P0001';
    END IF;
    IF length(v_note) > 500 OR (p_decision = 'reject' AND COALESCE(length(v_note), 0) < 3) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: note' USING ERRCODE = 'P0001';
    END IF;
    r := app.survey_for_caller(v_org, p_id, true);
    IF r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
    END IF;
    IF r.assigned_to = v_emp AND app.current_role() <> 'OWNER' THEN
        RAISE EXCEPTION 'SURVEY_SELF_DECISION' USING ERRCODE = 'P0001';
    END IF;
    v_status := CASE WHEN p_decision = 'approve' THEN 'approved' ELSE 'rejected' END;
    UPDATE public.field_surveys SET status = v_status, decided_by = v_emp, decided_at = now(),
        decision_note = v_note, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit(CASE WHEN p_decision = 'approve' THEN 'survey.approved' ELSE 'survey.rejected' END,
        'field_survey', p_id,
        jsonb_build_object('status', 'submitted'),
        jsonb_build_object('status', v_status, 'customer_id', r.customer_id, 'survey_score', r.survey_score),
        v_note, NULL,
        CASE WHEN p_decision = 'approve' THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN app.field_survey_json(v_org, p_id);
END;
$$;

-- 7. Photos: the entity type 'field_survey' ------------------------------------------------------

-- Re-created from its latest version (R04); the changes: the 'field_survey' line in the entity map
-- and its block (rule 4).
CREATE OR REPLACE FUNCTION public.register_file(
    p_id          uuid,
    p_path        text,
    p_original_name text,
    p_mime        text,
    p_size_bytes  bigint,
    p_sha256      text,
    p_purpose     public.file_purpose,
    p_entity_type text,
    p_entity_id   uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_permission(CASE p_purpose
        WHEN 'logo'             THEN 'org.settings_manage'
        WHEN 'product_image'    THEN 'catalog.manage'
        WHEN 'customer_id'      THEN 'customer.create'
        WHEN 'survey_photo'     THEN 'survey.submit'
        WHEN 'signature'        THEN 'installment.create'
        WHEN 'contract_pdf'     THEN 'installment.create'
        WHEN 'promissory_note'  THEN 'installment.create'
        WHEN 'delivery_proof'   THEN 'delivery.manage'
        WHEN 'expense_receipt'  THEN 'expense.create'
        WHEN 'legal_document'   THEN 'legal.manage'
        WHEN 'import'           THEN 'import.data'
        WHEN 'export'           THEN 'export.data'
        WHEN 'other'            THEN CASE WHEN p_entity_type='warranty_claim' THEN 'warranty.manage' ELSE 'org.settings_manage' END
    END);
    v_org   uuid := app.current_org_id();
    v_table text;
    v_found boolean;
    v_branch uuid;
    v_survey public.field_surveys;
BEGIN
    IF p_id IS NULL OR p_path IS NULL OR p_mime IS NULL OR p_size_bytes IS NULL
       OR p_size_bytes < 0 OR p_purpose IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: id, path, mime, size and purpose are required'
            USING ERRCODE = 'P0001';
    END IF;

    -- The object must sit under the caller's own shop: '<org id>/...', no '.', '..' or backslash.
    IF left(p_path, length(v_org::text) + 1) <> v_org::text || '/'
       OR p_path ~ '\\' OR p_path ~ '(^|/)\.{1,2}(/|$)' THEN
        RAISE EXCEPTION 'FILE_PATH_INVALID: the path must start with the shop id' USING ERRCODE = 'P0001';
    END IF;

    -- EC-142: the record the file points at. Same entity types as the API (files.rules.ts ENTITY_TABLES).
    IF p_entity_id IS NOT NULL AND p_entity_type IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an entity type is needed with an entity id' USING ERRCODE = 'P0001';
    END IF;
    IF p_entity_type IS NOT NULL THEN
        v_table := CASE p_entity_type
            WHEN 'customer'   THEN 'customers'
            WHEN 'product'    THEN 'products'
            WHEN 'expense'    THEN 'expenses'
            WHEN 'contract'   THEN 'contracts'
            WHEN 'legal_case' THEN 'legal_cases'
            WHEN 'delivery'   THEN 'deliveries'
            WHEN 'warranty_claim' THEN 'warranty_claims'
            WHEN 'guarantor'  THEN 'guarantors'
            WHEN 'field_survey' THEN 'field_surveys'
        END;
        IF v_table IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unknown entity type' USING ERRCODE = 'P0001';
        END IF;
        IF p_entity_id IS NOT NULL THEN
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1 AND organization_id = $2)', v_table)
                INTO v_found USING p_entity_id, v_org;
            IF NOT v_found THEN
                RAISE EXCEPTION 'NOT_FOUND: entity' USING ERRCODE = 'P0002';
            END IF;
        END IF;
    END IF;

    IF p_entity_type='warranty_claim' THEN
        IF p_entity_id IS NULL OR p_purpose<>'other' THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
        SELECT branch_id INTO v_branch FROM public.warranty_claims WHERE id=p_entity_id AND organization_id=v_org FOR UPDATE;
        PERFORM app.require_branch_access(v_branch);
        IF (SELECT count(*) FROM public.files WHERE organization_id=v_org AND entity_type='warranty_claim' AND entity_id=p_entity_id)>=5 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: at most five claim photos' USING ERRCODE='P0001'; END IF;
    END IF;

    -- R05: survey photos belong to an assigned survey of the caller, at most ten.
    IF p_entity_type = 'field_survey' OR p_purpose = 'survey_photo' THEN
        IF p_entity_type IS DISTINCT FROM 'field_survey' OR p_entity_id IS NULL OR p_purpose <> 'survey_photo' THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: a survey photo needs its survey' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_survey FROM public.field_surveys
        WHERE id = p_entity_id AND organization_id = v_org FOR UPDATE;
        IF v_survey.assigned_to <> v_emp THEN
            RAISE EXCEPTION 'SURVEY_NOT_ASSIGNEE' USING ERRCODE = 'P0001';
        END IF;
        IF v_survey.status <> 'assigned' THEN
            RAISE EXCEPTION 'SURVEY_WRONG_STATUS' USING ERRCODE = 'P0001';
        END IF;
        IF (SELECT count(*) FROM public.files WHERE organization_id = v_org AND entity_type = 'field_survey'
                                                AND entity_id = p_entity_id) >= 10 THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: at most ten survey photos' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    INSERT INTO public.files (id, organization_id, bucket, path, original_name, mime, size_bytes,
                              sha256, purpose, entity_type, entity_id, created_by)
    VALUES (p_id, v_org, 'tenant-files', p_path, p_original_name, p_mime, p_size_bytes,
            p_sha256, p_purpose, p_entity_type, p_entity_id, v_emp);

    PERFORM app.write_audit('file.upload', 'file', p_id, NULL,
        jsonb_build_object('purpose', p_purpose, 'size', p_size_bytes,
                           'entity_type', p_entity_type, 'entity_id', p_entity_id));
    RETURN p_id;
END;
$$;

-- 8. Grants: the ten public functions only -------------------------------------------------------

REVOKE ALL ON FUNCTION public.list_field_surveys(text, uuid, uuid, boolean, integer, integer),
    public.get_field_survey(uuid), public.list_customer_surveys(uuid), public.get_survey_requirement(uuid, text),
    public.assign_field_survey(jsonb), public.reassign_field_survey(uuid, uuid),
    public.cancel_field_survey(uuid, text), public.save_field_survey(uuid, jsonb),
    public.submit_field_survey(uuid, jsonb), public.decide_field_survey(uuid, text, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_field_surveys(text, uuid, uuid, boolean, integer, integer),
    public.get_field_survey(uuid), public.list_customer_surveys(uuid), public.get_survey_requirement(uuid, text),
    public.assign_field_survey(jsonb), public.reassign_field_survey(uuid, uuid),
    public.cancel_field_survey(uuid, text), public.save_field_survey(uuid, jsonb),
    public.submit_field_survey(uuid, jsonb), public.decide_field_survey(uuid, text, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_file(uuid, text, text, text, bigint, text,
                                               public.file_purpose, text, uuid) TO authenticated;
