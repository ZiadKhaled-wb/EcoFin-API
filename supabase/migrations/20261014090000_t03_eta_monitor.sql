-- T03 ETA submission monitor and corrections (EC-91). Rules: docs/eta/ERECEIPT_SPEC.md (section 13a).
--
-- Every fiscal row is in exactly one situation (app.fiscal_situation):
--   waiting      pending or submitted
--   accepted     accepted
--   cancelled    cancelled (a void, S07)
--   blocked      failed without a UUID (BLOCKED:...): fix the data, then retry (re-prepare)
--   send_failed  failed with a UUID: retry now (T02's lookup-then-resend path)
--   rejected     the ETA said Invalid: fix the data, then "correct and resend"
-- A problem is a blocked, send_failed or rejected row.
--
-- A rejected receipt is never plainly retried (the same bytes would be rejected again). A correction
-- is a background job: public.fiscal_request_correction (the user, fiscal.retry) queues `eta.correct`,
-- the worker rebuilds the receipt from the unchanged sale and the current master data, and stores it
-- with public.eta_store_correction (service role): a new UUID, the same previousUUID,
-- referenceOldUUID = the rejected UUID. The POS chain head moves only when the rejected receipt was
-- the newest of its POS.
--
-- Shop side (the user's token): fiscal_list, fiscal_details, fiscal_diagnose, fiscal_alert_summary,
-- fiscal_day_summary (read, fiscal.view); fiscal_request_correction, fiscal_assign_device,
-- fiscal_check_now, fiscal_retry_many, retry_fiscal_submission (write, fiscal.retry).
-- Worker side (service role only): eta_load_for_correction, eta_store_correction, eta_note_correction.
--
-- Replaced T02 function: public.retry_fiscal_submission (a rejected receipt -> USE_CORRECTION).

-- 1. The rejected UUID is never lost -------------------------------------------------------------------

ALTER TABLE public.fiscal_submissions ADD COLUMN reference_old_uuid text;
GRANT SELECT (reference_old_uuid) ON public.fiscal_submissions TO authenticated;

-- 2. The event log -------------------------------------------------------------------------------------

-- One row per change of a receipt's status, UUID or error. Never the payload.
CREATE TABLE public.fiscal_events (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organization_id   uuid NOT NULL,
    fiscal_id         uuid NOT NULL,
    at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    old_status        public.fiscal_status,
    new_status        public.fiscal_status NOT NULL,
    eta_uuid          text,
    message           text CHECK (length(message) <= 500),     -- last_error at that moment
    actor_employee_id uuid,                                    -- NULL for jobs
    FOREIGN KEY (fiscal_id, organization_id) REFERENCES public.fiscal_submissions (id, organization_id)
);
CREATE INDEX fiscal_events_fiscal_idx ON public.fiscal_events (fiscal_id, at);

ALTER TABLE public.fiscal_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY fiscal_events_tenant_read ON public.fiscal_events
    FOR SELECT TO authenticated
    USING (organization_id = (SELECT app.current_org_id()) AND (SELECT app.has_permission('fiscal.view')));
REVOKE ALL ON public.fiscal_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.fiscal_events TO authenticated;

CREATE TRIGGER trg_fiscal_events_append_only BEFORE UPDATE OR DELETE ON public.fiscal_events
    FOR EACH ROW EXECUTE FUNCTION app.forbid_update_delete();

CREATE FUNCTION app.fiscal_events_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.eta_uuid IS NOT DISTINCT FROM OLD.eta_uuid
       AND NEW.last_error IS NOT DISTINCT FROM OLD.last_error THEN
        RETURN NULL;
    END IF;
    INSERT INTO public.fiscal_events (organization_id, fiscal_id, old_status, new_status, eta_uuid, message,
                                      actor_employee_id)
    VALUES (NEW.organization_id, NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
            NEW.eta_uuid, left(NEW.last_error, 500), app.current_employee_id());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_fiscal_submissions_events AFTER INSERT OR UPDATE ON public.fiscal_submissions
    FOR EACH ROW EXECUTE FUNCTION app.fiscal_events_log();

-- Receipts that exist already start their timeline with where they are now.
INSERT INTO public.fiscal_events (organization_id, fiscal_id, at, new_status, eta_uuid, message)
SELECT f.organization_id, f.id, f.updated_at, f.status, f.eta_uuid, left(f.last_error, 500)
FROM public.fiscal_submissions f;

-- 3. Pure helpers --------------------------------------------------------------------------------------

CREATE FUNCTION app.fiscal_situation(p_status public.fiscal_status, p_uuid text, p_err text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT CASE p_status
        WHEN 'pending'   THEN 'waiting'
        WHEN 'submitted' THEN 'waiting'
        WHEN 'accepted'  THEN 'accepted'
        WHEN 'cancelled' THEN 'cancelled'
        WHEN 'rejected'  THEN 'rejected'
        ELSE CASE WHEN p_uuid IS NULL THEN 'blocked' ELSE 'send_failed' END
    END
$$;

-- When the ETA must have the receipt (docs/eta/ERECEIPT_SPEC.md section 13): 24 hours after issue for
-- a first submission, 96 hours for a correction (a rejected receipt waits for one; a row that carries
-- referenceOldUUID is one). Nothing to wait for once it is at the ETA, accepted or cancelled.
CREATE FUNCTION app.fiscal_deadline_at(p_status public.fiscal_status, p_issued_at timestamptz, p_reference_old text)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE
        WHEN p_issued_at IS NULL OR p_status IN ('accepted', 'cancelled', 'submitted') THEN NULL
        WHEN p_status = 'rejected' OR p_reference_old IS NOT NULL THEN p_issued_at + interval '96 hours'
        ELSE p_issued_at + interval '24 hours'
    END
$$;

CREATE FUNCTION app.fiscal_deadline_state(p_deadline_at timestamptz, p_now timestamptz DEFAULT now())
RETURNS text LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT CASE
        WHEN p_deadline_at IS NULL THEN 'ok'
        WHEN p_now > p_deadline_at THEN 'overdue'
        WHEN p_deadline_at - p_now < interval '4 hours' THEN 'due_soon'
        ELSE 'ok'
    END
$$;

-- 4. The receipt source of one fiscal row (the worker's loader) ----------------------------------------

-- The same document T02's eta_load_pending_for_device builds for a pending row, for any one row.
-- Carries the buyer's national ID: never log the result.
CREATE FUNCTION app.eta_receipt_source(p_fiscal_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'fiscal_id', f.id, 'organization_id', f.organization_id, 'environment', f.environment,
        'sale', jsonb_build_object(
            'id', s.id, 'number', s.number,
            'issued_at', to_char(s.issued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'prices_include_vat', s.prices_include_vat, 'total', s.total::text),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'line_no', l.line_no, 'quantity', l.quantity, 'unit_price', l.unit_price::text,
                'discount_amount', l.discount_amount::text,
                'tax_rate', l.tax_rate::numeric(5,2)::text, 'tax_amount', l.tax_amount::text,
                'line_total', l.line_total::text, 'sku', p.sku, 'name', p.name_ar,
                'eta_item_code', p.eta_item_code, 'eta_item_type', p.eta_item_type,
                'eta_tax_type', t.eta_tax_type, 'eta_subtype', t.eta_subtype) ORDER BY l.line_no)
            FROM public.sale_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            JOIN public.tax_classes t ON t.id = l.tax_class_id AND t.organization_id = l.organization_id
            WHERE l.organization_id = f.organization_id AND l.sale_id = s.id), '[]'::jsonb),
        'payments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('method', pay.method, 'amount', a.amount::text)
                             ORDER BY pay.number)
            FROM public.payment_allocations a
            JOIN public.payments pay ON pay.id = a.payment_id AND pay.organization_id = a.organization_id
            WHERE a.organization_id = f.organization_id AND a.sale_id = s.id), '[]'::jsonb),
        'customer', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
            'name', c.full_name, 'national_id', c.national_id, 'is_business', c.is_business,
            'tax_registration_no', c.tax_registration_no) END,
        'seller', jsonb_build_object(
            'rin', o.tax_registration_no, 'name', COALESCE(NULLIF(btrim(o.legal_name), ''), o.name),
            'activity_code', es.activity_code, 'branch_code', b.eta_branch_code,
            'governorate', b.governorate, 'city', b.city, 'street', b.address,
            'building_number', b.building_number),
        'device', CASE WHEN d.id IS NOT NULL THEN jsonb_build_object(
            'id', d.id, 'serial', d.eta_serial, 'status', d.eta_status,
            'is_active', d.is_active AND d.archived_at IS NULL) END)
    FROM public.fiscal_submissions f
    JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
    JOIN public.organizations o ON o.id = f.organization_id
    JOIN public.branches b ON b.id = f.branch_id AND b.organization_id = f.organization_id
    LEFT JOIN public.eta_settings es ON es.organization_id = f.organization_id
    LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = f.organization_id
    LEFT JOIN public.devices d ON d.id = f.device_id AND d.organization_id = f.organization_id
    WHERE f.id = p_fiscal_id AND f.doc_type = 'b2c_receipt'
$$;

-- 5. Diagnosis -----------------------------------------------------------------------------------------

-- What is wrong with a row, from the data as it is NOW (so a fix shows at once), what the person can do
-- about it, and whether that action can run now. No access check: callers have made it. Never a
-- national ID or the payload.
CREATE FUNCTION app.fiscal_diagnosis(p_f public.fiscal_submissions)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_sit text := app.fiscal_situation(p_f.status, p_f.eta_uuid, p_f.last_error);
    v_problems jsonb := '[]'::jsonb;
    v_data_problems integer := 0;
    v_sale public.sales; v_issued timestamptz; v_cust public.customers;
    v_dev public.devices; v_org public.organizations; v_br public.branches; v_es public.eta_settings;
    v_items jsonb; v_fields jsonb := '[]'::jsonb; v_action text; v_ready boolean; v_queued boolean;
    v_deadline timestamptz;
BEGIN
    SELECT COALESCE(s.issued_at, r.created_at, p_f.created_at) INTO v_issued
    FROM (SELECT 1) x
    LEFT JOIN public.sales s ON s.id = p_f.sale_id AND s.organization_id = p_f.organization_id
    LEFT JOIN public.sales_returns r ON r.id = p_f.return_id AND r.organization_id = p_f.organization_id;
    v_deadline := app.fiscal_deadline_at(p_f.status, v_issued, p_f.reference_old_uuid);
    v_queued := p_f.status = 'rejected' AND EXISTS (
        SELECT 1 FROM public.jobs j
        WHERE j.job_type = 'eta.correct' AND j.status IN ('queued', 'running')
          AND j.dedupe_key LIKE 'eta.correct:' || p_f.id::text || '%');

    IF v_sit IN ('blocked', 'rejected') AND p_f.sale_id IS NOT NULL THEN
        SELECT * INTO v_sale FROM public.sales s WHERE s.id = p_f.sale_id AND s.organization_id = p_f.organization_id;

        -- The POS: only a blocked receipt waits for one (a rejected one already has its own).
        IF v_sit = 'blocked' THEN
            IF p_f.device_id IS NULL THEN
                v_problems := v_problems || jsonb_build_object('code', 'NO_DEVICE', 'fixable', true,
                    'fix', 'assign_device', 'reason', 'missing');
                v_data_problems := v_data_problems + 1;
            ELSE
                SELECT * INTO v_dev FROM public.devices d
                WHERE d.id = p_f.device_id AND d.organization_id = p_f.organization_id;
                IF NOT FOUND OR NOT v_dev.is_active OR v_dev.archived_at IS NOT NULL OR v_dev.eta_status <> 'active'
                   OR NULLIF(btrim(v_dev.eta_serial), '') IS NULL THEN
                    v_problems := v_problems || jsonb_build_object('code', 'NO_DEVICE', 'fixable', true,
                        'fix', 'device', 'reason', 'not_active', 'device_id', p_f.device_id);
                    v_data_problems := v_data_problems + 1;
                END IF;
            END IF;
        END IF;

        -- Products without an ETA item code.
        SELECT jsonb_agg(jsonb_build_object('product_id', q.id, 'name', q.name_ar, 'sku', q.sku)
                         ORDER BY q.name_ar, q.id) INTO v_items
        FROM (SELECT DISTINCT p.id, p.name_ar, p.sku
              FROM public.sale_lines l
              JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
              WHERE l.sale_id = p_f.sale_id AND l.organization_id = p_f.organization_id
                AND (NULLIF(btrim(p.eta_item_code), '') IS NULL
                     OR p.eta_item_type IS NULL OR p.eta_item_type NOT IN ('EGS', 'GS1'))) q;
        IF v_items IS NOT NULL THEN
            v_problems := v_problems || jsonb_build_object('code', 'ITEM_CODE', 'fixable', true,
                'fix', 'product', 'products', v_items);
            v_data_problems := v_data_problems + 1;
        END IF;

        -- The seller: the shop, its ETA settings and the branch.
        SELECT * INTO v_org FROM public.organizations o WHERE o.id = p_f.organization_id;
        SELECT * INTO v_br FROM public.branches b WHERE b.id = p_f.branch_id AND b.organization_id = p_f.organization_id;
        SELECT * INTO v_es FROM public.eta_settings s WHERE s.organization_id = p_f.organization_id;
        IF regexp_replace(COALESCE(v_org.tax_registration_no, ''), '\D', '', 'g') !~ '^\d{9}$' THEN
            v_fields := v_fields || jsonb_build_object('field', 'rin', 'fix', 'shop_profile');
        END IF;
        IF NULLIF(btrim(v_es.activity_code), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'activity_code', 'fix', 'eta_settings');
        END IF;
        IF NULLIF(btrim(v_br.eta_branch_code), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'branch_code', 'fix', 'branch');
        END IF;
        IF NULLIF(btrim(v_br.governorate), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'governorate', 'fix', 'branch');
        END IF;
        IF NULLIF(btrim(v_br.city), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'city', 'fix', 'branch');
        END IF;
        IF NULLIF(btrim(v_br.address), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'street', 'fix', 'branch');
        END IF;
        IF NULLIF(btrim(v_br.building_number), '') IS NULL THEN
            v_fields := v_fields || jsonb_build_object('field', 'building_number', 'fix', 'branch');
        END IF;
        IF jsonb_array_length(v_fields) > 0 THEN
            v_problems := v_problems || jsonb_build_object('code', 'SELLER_DATA', 'fixable', true,
                'fix', CASE WHEN v_fields @> '[{"fix":"branch"}]' THEN 'branch'
                            WHEN v_fields @> '[{"fix":"shop_profile"}]' THEN 'shop_profile'
                            ELSE 'eta_settings' END,
                'branch_id', p_f.branch_id, 'fields', v_fields);
            v_data_problems := v_data_problems + 1;
        END IF;

        -- The buyer (docs/eta/ERECEIPT_SPEC.md section 7). 150,000 EGP and over needs a person's
        -- national ID and name; a business buyer always needs its tax number.
        IF v_sale.customer_id IS NULL THEN
            IF v_sale.total >= 150000 THEN
                v_problems := v_problems || jsonb_build_object('code', 'BUYER_MISSING', 'fixable', false, 'fix', NULL);
                v_data_problems := v_data_problems + 1;
            END IF;
        ELSE
            SELECT * INTO v_cust FROM public.customers c
            WHERE c.id = v_sale.customer_id AND c.organization_id = p_f.organization_id;
            IF v_cust.is_business THEN
                IF regexp_replace(COALESCE(v_cust.tax_registration_no, ''), '\D', '', 'g') !~ '^\d{9}$'
                   OR regexp_replace(COALESCE(v_cust.tax_registration_no, ''), '\D', '', 'g')
                      = regexp_replace(COALESCE(v_org.tax_registration_no, ''), '\D', '', 'g')
                   OR NULLIF(btrim(v_cust.full_name), '') IS NULL THEN
                    v_problems := v_problems || jsonb_build_object('code', 'BUYER_ID', 'fixable', true,
                        'fix', 'customer', 'customer_id', v_cust.id, 'reason', 'business_tax_number');
                    v_data_problems := v_data_problems + 1;
                END IF;
            ELSIF v_sale.total >= 150000 AND (
                    regexp_replace(COALESCE(v_cust.national_id, ''), '\D', '', 'g') !~ '^\d{14}$'
                    OR NULLIF(btrim(v_cust.full_name), '') IS NULL) THEN
                v_problems := v_problems || jsonb_build_object('code', 'BUYER_ID', 'fixable', true,
                    'fix', 'customer', 'customer_id', v_cust.id, 'reason', 'national_id');
                v_data_problems := v_data_problems + 1;
            END IF;
        END IF;
    END IF;

    IF v_sit = 'rejected' THEN
        v_problems := v_problems || jsonb_build_object('code', 'ETA_REJECTED', 'fixable', true, 'fix', NULL,
            'last_error', left(p_f.last_error, 2000));
    END IF;

    v_action := CASE
        WHEN v_sit = 'blocked' AND p_f.device_id IS NULL THEN 'assign_device'
        WHEN v_sit = 'blocked' THEN 'retry'
        WHEN v_sit = 'send_failed' THEN 'retry_now'
        WHEN v_sit = 'rejected' THEN 'correct'
        WHEN p_f.status = 'submitted' AND p_f.eta_submission_uuid IS NOT NULL THEN 'check_now'
    END;
    v_ready := CASE
        WHEN v_action = 'assign_device' THEN true
        WHEN v_action IN ('retry', 'correct') THEN v_data_problems = 0 AND NOT v_queued
        WHEN v_action IN ('retry_now', 'check_now') THEN true
        ELSE false
    END;

    RETURN jsonb_build_object('situation', v_sit, 'action', v_action, 'ready', v_ready,
        'correction_queued', v_queued, 'deadline_at', v_deadline,
        'deadline_state', app.fiscal_deadline_state(v_deadline), 'problems', v_problems);
END;
$$;

-- A receipt of the caller's shop and branches, or FISCAL_NOT_FOUND (another shop's and an
-- inaccessible branch's look the same). p_lock: FOR UPDATE.
CREATE FUNCTION app.fiscal_visible(p_id uuid, p_lock boolean DEFAULT false)
RETURNS public.fiscal_submissions LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_f public.fiscal_submissions; v_org uuid := app.current_org_id();
BEGIN
    IF p_lock THEN
        SELECT * INTO v_f FROM public.fiscal_submissions f
        WHERE f.id = p_id AND f.organization_id = v_org FOR UPDATE;
    ELSE
        SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.id = p_id AND f.organization_id = v_org;
    END IF;
    IF NOT FOUND OR NOT app.has_branch_access(v_f.branch_id) THEN
        RAISE EXCEPTION 'FISCAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_f;
END;
$$;

CREATE FUNCTION app.require_fiscal_view()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT app.has_permission('fiscal.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: fiscal.view' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- 6. Reading (fiscal.view) -----------------------------------------------------------------------------

CREATE FUNCTION public.fiscal_diagnose(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    PERFORM app.require_fiscal_view();
    RETURN app.fiscal_diagnosis(app.fiscal_visible(p_id));
END;
$$;

-- The receipts of the caller's branches: an array of rows, each with total_count. Sorted overdue, due
-- soon, problems, the rest; newest first inside each group.
CREATE FUNCTION public.fiscal_list(p_branch_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL,
                                   p_situation text DEFAULT NULL, p_query text DEFAULT NULL,
                                   p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_org uuid; v_like text; v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
    v_offset integer := GREATEST(COALESCE(p_offset, 0), 0); v_out jsonb;
BEGIN
    PERFORM app.require_fiscal_view();
    v_org := app.current_org_id();
    IF p_situation IS NOT NULL AND p_situation NOT IN
       ('waiting', 'accepted', 'cancelled', 'blocked', 'send_failed', 'rejected', 'problem') THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: situation' USING ERRCODE = 'P0001';
    END IF;
    IF length(p_query) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: query' USING ERRCODE = 'P0001';
    END IF;
    v_like := NULLIF(btrim(p_query), '');
    IF v_like IS NOT NULL THEN
        v_like := replace(replace(replace(v_like, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    END IF;

    WITH base AS (
        SELECT f.id, f.internal_id, f.status, f.last_error, f.branch_id, f.device_id,
               COALESCE(f.sale_id, r.sale_id) AS sale_id,
               COALESCE(s.issued_at, r.created_at, f.created_at) AS issued_at,
               COALESCE(s.total, r.total) AS total,
               app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation,
               app.fiscal_deadline_at(f.status, COALESCE(s.issued_at, r.created_at, f.created_at),
                                      f.reference_old_uuid) AS deadline_at,
               (COALESCE(s.issued_at, r.created_at, f.created_at) AT TIME ZONE o.timezone)::date AS shop_date
        FROM public.fiscal_submissions f
        JOIN public.organizations o ON o.id = f.organization_id
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        WHERE f.organization_id = v_org AND app.has_branch_access(f.branch_id)
          AND (p_branch_id IS NULL OR f.branch_id = p_branch_id)
          AND (v_like IS NULL OR f.internal_id ILIKE v_like OR f.eta_uuid LIKE lower(v_like))
    ), picked AS (
        SELECT b.*, app.fiscal_deadline_state(b.deadline_at) AS deadline_state
        FROM base b
        WHERE (p_from IS NULL OR b.shop_date >= p_from) AND (p_to IS NULL OR b.shop_date <= p_to)
          AND (p_situation IS NULL
               OR (p_situation = 'problem' AND b.situation IN ('blocked', 'send_failed', 'rejected'))
               OR b.situation = p_situation)
    ), page AS (
        SELECT p.*, count(*) OVER () AS total_count,
               row_number() OVER (ORDER BY
                   CASE p.deadline_state WHEN 'overdue' THEN 0 WHEN 'due_soon' THEN 1
                        ELSE CASE WHEN p.situation IN ('blocked', 'send_failed', 'rejected') THEN 2 ELSE 3 END END,
                   p.issued_at DESC, p.id) AS rn
        FROM picked p
        ORDER BY rn
        LIMIT v_limit OFFSET v_offset
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', g.id, 'sale_id', g.sale_id, 'sale_number', g.internal_id, 'issued_at', g.issued_at,
               'branch_id', g.branch_id, 'branch_name', br.name, 'device_id', g.device_id, 'device_name', d.name,
               'total', g.total::text, 'status', g.status, 'situation', g.situation,
               'short_error', left(g.last_error, 120), 'deadline_at', g.deadline_at,
               'deadline_state', g.deadline_state, 'total_count', g.total_count) ORDER BY g.rn), '[]'::jsonb)
    INTO v_out
    FROM page g
    JOIN public.branches br ON br.id = g.branch_id AND br.organization_id = v_org
    LEFT JOIN public.devices d ON d.id = g.device_id AND d.organization_id = v_org;
    RETURN v_out;
END;
$$;

CREATE FUNCTION public.fiscal_details(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_f public.fiscal_submissions; v_org uuid; v_diag jsonb; v_row jsonb; v_sale jsonb; v_events jsonb;
BEGIN
    PERFORM app.require_fiscal_view();
    v_org := app.current_org_id();
    v_f := app.fiscal_visible(p_id);
    v_diag := app.fiscal_diagnosis(v_f);

    SELECT jsonb_build_object(
               'id', f.id, 'doc_type', f.doc_type, 'status', f.status,
               'situation', app.fiscal_situation(f.status, f.eta_uuid, f.last_error),
               'sale_number', f.internal_id, 'issued_at', COALESCE(s.issued_at, r.created_at, f.created_at),
               'total', COALESCE(s.total, r.total)::text,
               'branch_id', f.branch_id, 'branch_name', b.name, 'device_id', f.device_id, 'device_name', d.name,
               'environment', f.environment, 'eta_uuid', f.eta_uuid, 'previous_uuid', f.previous_uuid,
               'reference_old_uuid', f.reference_old_uuid, 'eta_long_id', f.eta_long_id,
               'eta_submission_uuid', f.eta_submission_uuid, 'attempts', f.attempts,
               'next_retry_at', f.next_retry_at, 'last_error', f.last_error,
               'submitted_at', f.submitted_at, 'accepted_at', f.accepted_at, 'created_at', f.created_at,
               'deadline_at', v_diag -> 'deadline_at', 'deadline_state', v_diag -> 'deadline_state'),
           jsonb_build_object('id', COALESCE(f.sale_id, r.sale_id), 'number', COALESCE(s.number, rs.number))
    INTO v_row, v_sale
    FROM public.fiscal_submissions f
    JOIN public.branches b ON b.id = f.branch_id AND b.organization_id = f.organization_id
    LEFT JOIN public.devices d ON d.id = f.device_id AND d.organization_id = f.organization_id
    LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
    LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
    LEFT JOIN public.sales rs ON rs.id = r.sale_id AND rs.organization_id = f.organization_id
    WHERE f.id = p_id AND f.organization_id = v_org;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', e.id, 'at', e.at, 'old_status', e.old_status, 'new_status', e.new_status,
               'eta_uuid', e.eta_uuid, 'message', e.message, 'actor_employee_id', e.actor_employee_id)
               ORDER BY e.at, e.id), '[]'::jsonb)
    INTO v_events
    FROM public.fiscal_events e WHERE e.fiscal_id = p_id AND e.organization_id = v_org;

    RETURN jsonb_build_object('row', v_row, 'situation', v_row ->> 'situation', 'diagnosis', v_diag,
                              'events', v_events, 'sale', v_sale);
END;
$$;

CREATE FUNCTION public.fiscal_alert_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_out jsonb;
BEGIN
    PERFORM app.require_fiscal_view();
    v_org := app.current_org_id();
    SELECT jsonb_build_object(
               'blocked', count(*) FILTER (WHERE x.situation = 'blocked'),
               'send_failed', count(*) FILTER (WHERE x.situation = 'send_failed'),
               'rejected', count(*) FILTER (WHERE x.situation = 'rejected'),
               'due_soon', count(*) FILTER (WHERE x.state = 'due_soon'),
               'overdue', count(*) FILTER (WHERE x.state = 'overdue'),
               'accepted_today', count(*) FILTER (WHERE x.status = 'accepted' AND x.accepted_date = x.today))
    INTO v_out
    FROM (
        SELECT f.status, app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation,
               app.fiscal_deadline_state(app.fiscal_deadline_at(f.status,
                   COALESCE(s.issued_at, r.created_at, f.created_at), f.reference_old_uuid)) AS state,
               (f.accepted_at AT TIME ZONE o.timezone)::date AS accepted_date,
               (now() AT TIME ZONE o.timezone)::date AS today
        FROM public.fiscal_submissions f
        JOIN public.organizations o ON o.id = f.organization_id
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        WHERE f.organization_id = v_org AND app.has_branch_access(f.branch_id)
    ) x;
    RETURN v_out;
END;
$$;

-- For the day close (K04): the receipts of the sales (and returns) of one branch and business day, by
-- situation. all_accepted: nothing is still waiting or in trouble (a void's cancelled receipt is not).
CREATE FUNCTION public.fiscal_day_summary(p_branch_id uuid, p_business_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_out jsonb;
BEGIN
    PERFORM app.require_fiscal_view();
    v_org := app.current_org_id();
    IF p_branch_id IS NULL OR p_business_date IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: branch and date' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    SELECT jsonb_build_object(
               'branch_id', p_branch_id, 'business_date', p_business_date, 'total', count(*),
               'waiting', count(*) FILTER (WHERE x.situation = 'waiting'),
               'accepted', count(*) FILTER (WHERE x.situation = 'accepted'),
               'cancelled', count(*) FILTER (WHERE x.situation = 'cancelled'),
               'blocked', count(*) FILTER (WHERE x.situation = 'blocked'),
               'send_failed', count(*) FILTER (WHERE x.situation = 'send_failed'),
               'rejected', count(*) FILTER (WHERE x.situation = 'rejected'),
               'all_accepted', count(*) FILTER (WHERE x.situation NOT IN ('accepted', 'cancelled')) = 0)
    INTO v_out
    FROM (
        SELECT app.fiscal_situation(f.status, f.eta_uuid, f.last_error) AS situation
        FROM public.fiscal_submissions f
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        LEFT JOIN public.sales_returns r ON r.id = f.return_id AND r.organization_id = f.organization_id
        WHERE f.organization_id = v_org AND f.branch_id = p_branch_id
          AND COALESCE(s.business_date, r.business_date) = p_business_date
    ) x;
    RETURN v_out;
END;
$$;

-- 7. T02's retry: a rejected receipt is corrected, never resent as it is ---------------------------------

-- Copy of T02's body (20261012120000_t02_eta_receipts.sql); the one change is the USE_CORRECTION check
-- at the start of the status checks.
CREATE OR REPLACE FUNCTION public.retry_fiscal_submission(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_f public.fiscal_submissions;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    SELECT * INTO v_f FROM public.fiscal_submissions f
    WHERE f.id = p_id AND f.organization_id = v_org FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_f.branch_id) THEN
        RAISE EXCEPTION 'FISCAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status = 'rejected' THEN
        RAISE EXCEPTION 'USE_CORRECTION: a rejected receipt is corrected, not resent' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status NOT IN ('failed', 'rejected') THEN
        RAISE EXCEPTION 'FISCAL_NOT_RETRYABLE: the receipt is %', v_f.status USING ERRCODE = 'P0001';
    END IF;
    -- A receipt made for one ETA system is never sent to the other.
    IF v_f.environment IS DISTINCT FROM (SELECT s.environment FROM public.eta_settings s
                                         WHERE s.organization_id = v_org) THEN
        RAISE EXCEPTION 'ETA_ENV_MISMATCH: the receipt belongs to %', v_f.environment USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.fiscal_submissions f
       SET status = 'pending', next_retry_at = now(), updated_at = now()
     WHERE f.id = p_id;
    IF v_f.eta_uuid IS NULL THEN
        PERFORM app.eta_enqueue(v_org, 'eta.prepare',
            'eta.prepare:' || COALESCE(v_f.device_id, v_f.branch_id)::text,
            jsonb_build_object('device_id', v_f.device_id, 'branch_id', v_f.branch_id));
    ELSE
        PERFORM app.eta_enqueue(v_org, 'eta.submit', 'eta.submit:' || v_f.device_id::text,
            jsonb_build_object('device_id', v_f.device_id));
    END IF;

    PERFORM app.write_audit('fiscal.retry_requested', 'fiscal_submission', p_id,
        jsonb_build_object('status', v_f.status, 'last_error', v_f.last_error),
        jsonb_build_object('status', 'pending', 'internal_id', v_f.internal_id, 'attempts', v_f.attempts),
        NULL, v_f.branch_id);
    RETURN jsonb_build_object('id', p_id, 'status', 'pending');
END;
$$;

-- 8. Writing (fiscal.retry) ----------------------------------------------------------------------------

-- Queues the correction of a rejected receipt (eta.correct). The worker rebuilds it.
CREATE FUNCTION public.fiscal_request_correction(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_f public.fiscal_submissions;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    v_f := app.fiscal_visible(p_id, true);
    IF v_f.status <> 'rejected' THEN
        RAISE EXCEPTION 'NOT_REJECTED: the receipt is %', v_f.status USING ERRCODE = 'P0001';
    END IF;
    IF v_f.environment IS DISTINCT FROM (SELECT s.environment FROM public.eta_settings s
                                         WHERE s.organization_id = v_org) THEN
        RAISE EXCEPTION 'ETA_ENV_MISMATCH: the receipt belongs to %', v_f.environment USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.jobs j
               WHERE j.job_type = 'eta.correct' AND j.status IN ('queued', 'running')
                 AND j.dedupe_key LIKE 'eta.correct:' || p_id::text || '%') THEN
        RAISE EXCEPTION 'CORRECTION_QUEUED' USING ERRCODE = 'P0001';
    END IF;

    PERFORM app.eta_enqueue(v_org, 'eta.correct', 'eta.correct:' || p_id::text,
        jsonb_build_object('fiscal_id', p_id, 'expected_old_uuid', v_f.eta_uuid));

    PERFORM app.write_audit('fiscal.correction_requested', 'fiscal_submission', p_id,
        jsonb_build_object('status', v_f.status, 'eta_uuid', v_f.eta_uuid, 'last_error', left(v_f.last_error, 500)),
        jsonb_build_object('status', v_f.status, 'internal_id', v_f.internal_id, 'correction', 'queued'),
        NULL, v_f.branch_id);
    RETURN jsonb_build_object('id', p_id, 'status', v_f.status, 'queued', true);
END;
$$;

-- A receipt of a sale made before POS devices (BLOCKED:NO_DEVICE) gets a POS of its own branch, then is
-- prepared again. Only the fiscal row changes; the sale never does.
CREATE FUNCTION public.fiscal_assign_device(p_id uuid, p_device_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_f public.fiscal_submissions; v_d public.devices;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    v_f := app.fiscal_visible(p_id, true);
    IF app.fiscal_situation(v_f.status, v_f.eta_uuid, v_f.last_error) <> 'blocked'
       OR v_f.last_error IS NULL OR v_f.last_error NOT LIKE 'BLOCKED:NO_DEVICE%' THEN
        RAISE EXCEPTION 'NOT_BLOCKED_NO_DEVICE' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_d FROM public.devices d
    WHERE d.id = p_device_id AND d.organization_id = v_org FOR SHARE;
    IF NOT FOUND OR NOT v_d.is_active OR v_d.archived_at IS NOT NULL OR v_d.branch_id <> v_f.branch_id THEN
        RAISE EXCEPTION 'DEVICE_INVALID_FOR_RECEIPT' USING ERRCODE = 'P0001';
    END IF;

    -- A receipt made for one ETA system is never sent to the other (as in the retry).
    IF v_f.environment IS DISTINCT FROM (SELECT s.environment FROM public.eta_settings s
                                         WHERE s.organization_id = v_org) THEN
        RAISE EXCEPTION 'ETA_ENV_MISMATCH: the receipt belongs to %', v_f.environment USING ERRCODE = 'P0001';
    END IF;

    -- The receipt gets its POS and goes back in the queue to be built (the retry's re-prepare), with one
    -- audit row of its own.
    UPDATE public.fiscal_submissions f
       SET device_id = p_device_id, status = 'pending', next_retry_at = now(), updated_at = now()
     WHERE f.id = p_id;
    PERFORM app.eta_enqueue(v_org, 'eta.prepare', 'eta.prepare:' || p_device_id::text,
        jsonb_build_object('device_id', p_device_id, 'branch_id', v_f.branch_id));
    PERFORM app.write_audit('fiscal.device_assigned', 'fiscal_submission', p_id,
        jsonb_build_object('device_id', v_f.device_id, 'status', v_f.status),
        jsonb_build_object('device_id', p_device_id, 'status', 'pending'),
        NULL, v_f.branch_id);
    RETURN jsonb_build_object('id', p_id, 'status', 'pending');
END;
$$;

-- "Check now": the poll of a submitted receipt's submission, at once.
CREATE FUNCTION public.fiscal_check_now(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_f public.fiscal_submissions;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    v_f := app.fiscal_visible(p_id, true);
    IF v_f.status <> 'submitted' OR v_f.eta_submission_uuid IS NULL THEN
        RAISE EXCEPTION 'NOT_SUBMITTED: the receipt is %', v_f.status USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.eta_enqueue(v_org, 'eta.poll', 'eta.poll:' || v_f.eta_submission_uuid || ':0',
        jsonb_build_object('submission_uuid', v_f.eta_submission_uuid, 'device_id', v_f.device_id, 'n', 0), 0);
    PERFORM app.write_audit('fiscal.check_requested', 'fiscal_submission', p_id,
        jsonb_build_object('status', v_f.status), jsonb_build_object('status', v_f.status, 'poll', 'queued'),
        NULL, v_f.branch_id);
    RETURN jsonb_build_object('id', p_id, 'status', v_f.status, 'queued', true);
END;
$$;

-- The single-row rule for each receipt: blocked -> re-prepare, send_failed -> retry, rejected -> request
-- a correction. A receipt that is not eligible, not ready, or not the caller's is skipped with its reason.
CREATE FUNCTION public.fiscal_retry_many(p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_id uuid; v_f public.fiscal_submissions; v_diag jsonb; v_action text;
    v_done integer := 0; v_skipped jsonb := '[]'::jsonb; v_seen uuid[] := '{}'::uuid[]; v_reason text;
BEGIN
    v_emp := app.require_permission('fiscal.retry');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    IF p_ids IS NULL OR cardinality(p_ids) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: 1 to 200 receipts' USING ERRCODE = 'P0001';
    END IF;

    FOREACH v_id IN ARRAY p_ids LOOP
        IF v_id IS NULL OR v_id = ANY (v_seen) THEN
            CONTINUE;
        END IF;
        v_seen := v_seen || v_id;
        v_reason := NULL;
        BEGIN
            v_f := app.fiscal_visible(v_id);
            v_diag := app.fiscal_diagnosis(v_f);
            v_action := v_diag ->> 'action';
            IF v_action IS NULL OR v_action = 'check_now' THEN
                v_reason := 'NOT_ELIGIBLE';
            ELSIF v_action = 'assign_device' OR NOT (v_diag ->> 'ready')::boolean THEN
                v_reason := 'NOT_READY';
            ELSIF v_action = 'correct' THEN
                PERFORM public.fiscal_request_correction(v_id);
            ELSE
                PERFORM public.retry_fiscal_submission(v_id);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_reason := COALESCE(substring(SQLERRM FROM '^[A-Z][A-Z_]+'), 'FAILED');
        END;
        IF v_reason IS NULL THEN
            v_done := v_done + 1;
        ELSE
            v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', v_reason);
        END IF;
    END LOOP;

    PERFORM app.write_audit('fiscal.retry_many', 'fiscal_submission', NULL,
        NULL, jsonb_build_object('asked', cardinality(v_seen), 'done', v_done,
                                 'skipped', jsonb_array_length(v_skipped)));
    RETURN jsonb_build_object('done', v_done, 'skipped', v_skipped);
END;
$$;

-- 9. Worker side (service role only) -------------------------------------------------------------------

-- A rejected receipt with everything its correction is built from: the row, the stored receipt text
-- (to see whether anything changed) and the sale as it is now. NULL when the row is not found or is not
-- a sale's receipt. Carries the buyer's national ID: never log the result.
CREATE FUNCTION public.eta_load_for_correction(p_fiscal_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('status', f.status, 'eta_uuid', f.eta_uuid, 'previous_uuid', COALESCE(f.previous_uuid, ''),
                              'last_error', f.last_error, 'stored_receipt_json', f.payload ->> 'receipt_json',
                              'row', app.eta_receipt_source(f.id))
    FROM public.fiscal_submissions f WHERE f.id = p_fiscal_id AND f.doc_type = 'b2c_receipt'
$$;

-- Stores a correction, or changes nothing (CORRECTION_CONFLICT: the row is no longer the rejected receipt
-- the request saw). One transaction: the row, the POS chain head and the submit job.
CREATE FUNCTION public.eta_store_correction(p_id uuid, p_expected_old_uuid text, p_new_uuid text, p_payload jsonb,
                                            p_qr text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_f public.fiscal_submissions; v_head text;
BEGIN
    IF p_new_uuid IS NULL OR p_new_uuid !~ '^[0-9a-f]{64}$' OR p_expected_old_uuid IS NULL
       OR p_new_uuid = p_expected_old_uuid
       OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR NULLIF(p_qr, '') IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: corrected receipt' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.id = p_id FOR UPDATE;
    IF NOT FOUND OR v_f.status <> 'rejected' OR v_f.eta_uuid IS DISTINCT FROM p_expected_old_uuid THEN
        RAISE EXCEPTION 'CORRECTION_CONFLICT' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.device_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a receipt needs a POS' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.fiscal_submissions f
       SET eta_uuid = p_new_uuid, reference_old_uuid = p_expected_old_uuid, qr_payload = p_qr,
           payload = (COALESCE(f.payload, '{}'::jsonb) - 'sent' - 'receipt_json') || p_payload,   -- keeps the deadline mark
           status = 'pending', attempts = 0, last_error = NULL, next_retry_at = now(),
           eta_long_id = NULL, eta_submission_uuid = NULL, submitted_at = NULL, updated_at = now()
     WHERE f.id = p_id;

    -- The POS chain head follows only when the rejected receipt was the newest: later receipts chain from
    -- the head already, and moving it would fork the chain.
    SELECT d.eta_last_uuid INTO v_head FROM public.devices d WHERE d.id = v_f.device_id FOR UPDATE;
    IF v_head = p_expected_old_uuid THEN
        UPDATE public.devices d SET eta_last_uuid = p_new_uuid WHERE d.id = v_f.device_id;
    END IF;

    PERFORM app.eta_enqueue(v_f.organization_id, 'eta.submit', 'eta.submit:' || v_f.device_id::text,
        jsonb_build_object('device_id', v_f.device_id));
END;
$$;

-- The correction was not stored: the reason replaces the error shown (the status stays rejected).
-- true when it was written; false when the row is no longer the rejected receipt the request saw.
CREATE FUNCTION public.eta_note_correction(p_id uuid, p_expected_old_uuid text, p_error text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NULLIF(btrim(p_error), '') IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: correction note' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.fiscal_submissions f
       SET last_error = left(p_error, 2000), updated_at = now()
     WHERE f.id = p_id AND f.status = 'rejected' AND f.eta_uuid = p_expected_old_uuid;
    RETURN FOUND;
END;
$$;

-- 10. Grants -------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.fiscal_events_log(), app.fiscal_situation(public.fiscal_status, text, text),
    app.fiscal_deadline_at(public.fiscal_status, timestamptz, text), app.fiscal_deadline_state(timestamptz, timestamptz),
    app.eta_receipt_source(uuid), app.fiscal_diagnosis(public.fiscal_submissions),
    app.fiscal_visible(uuid, boolean), app.require_fiscal_view()
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.retry_fiscal_submission(uuid), public.fiscal_diagnose(uuid),
    public.fiscal_list(uuid, date, date, text, text, integer, integer), public.fiscal_details(uuid),
    public.fiscal_alert_summary(), public.fiscal_day_summary(uuid, date), public.fiscal_request_correction(uuid),
    public.fiscal_assign_device(uuid, uuid), public.fiscal_check_now(uuid), public.fiscal_retry_many(uuid[])
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.retry_fiscal_submission(uuid), public.fiscal_diagnose(uuid),
    public.fiscal_list(uuid, date, date, text, text, integer, integer), public.fiscal_details(uuid),
    public.fiscal_alert_summary(), public.fiscal_day_summary(uuid, date), public.fiscal_request_correction(uuid),
    public.fiscal_assign_device(uuid, uuid), public.fiscal_check_now(uuid), public.fiscal_retry_many(uuid[])
    TO authenticated;

REVOKE ALL ON FUNCTION public.eta_load_for_correction(uuid),
    public.eta_store_correction(uuid, text, text, jsonb, text), public.eta_note_correction(uuid, text, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.eta_load_for_correction(uuid),
    public.eta_store_correction(uuid, text, text, jsonb, text), public.eta_note_correction(uuid, text, text)
    TO service_role;
