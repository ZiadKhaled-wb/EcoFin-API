-- T02 ETA e-receipts, B2C (EC-90, D67). The format, codes and deadlines: docs/eta/ERECEIPT_SPEC.md.
--
-- Every consumer sale gets a fiscal record in the sale's own transaction (a trigger on sales: the
-- sale function is not touched). The API then builds the ETA receipt, computes its UUID in issue
-- order per POS and stores both with a compare-and-set on the POS chain (devices.eta_last_uuid).
-- Jobs (F13) submit the prepared receipts and poll the result:
--   eta.prepare  build what is pending for a POS            (queued by the sale)
--   eta.submit   send the prepared receipts of a POS        (queued when a receipt is prepared)
--   eta.poll     read the result of one submission          (queued when a receipt is submitted)
-- The follow-up job is queued by the same statement that changes the receipt, so a crash between
-- the two can't leave a receipt without a job.
--
-- Shop side (PostgREST, the user's token): get_eta_settings, set_eta_settings, list_devices,
-- set_device_eta, retry_fiscal_submission.
-- Worker side (PostgREST, service role only, like F13's jobs_*): eta_load_pending_for_device,
-- eta_credentials, eta_store_prepared, eta_claim_for_submit, eta_mark, eta_block,
-- eta_load_submitted, eta_claim_deadline_alerts, eta_enqueue, eta_sale_status. They are in public
-- because the API reaches the database through PostgREST, which exposes only that schema.
--
-- Secrets (the shop's client secret, each POS's pre-shared key) are in Supabase Vault; the tables
-- hold only the vault ids, which `authenticated` can't read.

CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA vault;

-- 1. Columns -------------------------------------------------------------------------------------------

ALTER TABLE public.devices
    ADD COLUMN eta_model_framework        text,
    ADD COLUMN eta_preshared_key_vault_id uuid,    -- the key itself is in Vault
    ADD COLUMN eta_last_uuid              text;    -- UUID of this POS's last prepared receipt (the chain's tail)

ALTER TABLE public.branches ADD COLUMN building_number text;   -- ETA branchAddress.buildingNumber

ALTER TABLE public.fiscal_submissions
    ADD COLUMN eta_submission_uuid text,           -- the ETA submission this receipt went in (polled)
    ADD COLUMN previous_uuid       text;           -- the previousUUID this receipt was hashed with

-- devices had a table-wide SELECT, which would show the new vault id: column grants instead, as
-- eta_settings has for client_secret_vault_id. A column added to devices later needs its own GRANT.
REVOKE SELECT ON public.devices FROM authenticated;
DO $$
DECLARE v_cols text;
BEGIN
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO v_cols
    FROM pg_attribute a
    WHERE a.attrelid = 'public.devices'::regclass AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname <> 'eta_preshared_key_vault_id';
    EXECUTE format('GRANT SELECT (%s) ON public.devices TO authenticated', v_cols);
END $$;
-- fiscal_submissions already has column grants (payload is hidden): the new columns are added.
GRANT SELECT (eta_submission_uuid, previous_uuid) ON public.fiscal_submissions TO authenticated;

-- O01's branch functions, with the building number (the new parameter is last and optional, so
-- every existing call still works). Nothing else in them changes.
DROP FUNCTION public.create_branch(text, text, text, text, text, text, text);
DROP FUNCTION public.update_branch(uuid, text, text, text, text, text, text, uuid);

CREATE FUNCTION public.create_branch(p_name text, p_code text, p_address text, p_city text, p_governorate text,
                                     p_phone text, p_eta_branch_code text, p_building_number text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid; v_code text; v_constraint text;
BEGIN
    v_emp := app.require_permission('branch.manage');
    v_org := app.current_org_id();
    IF NULLIF(btrim(p_name), '') IS NULL OR length(btrim(p_name)) > 100 THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    v_code := upper(btrim(p_code));
    IF v_code IS NULL OR v_code !~ '^[A-Z0-9]{1,6}$' THEN
        RAISE EXCEPTION 'BRANCH_CODE_INVALID' USING ERRCODE = 'P0001';
    END IF;
    IF length(p_eta_branch_code) > 20 OR length(p_building_number) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.organizations WHERE id = v_org FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.branches WHERE organization_id = v_org AND code = v_code) THEN
        RAISE EXCEPTION 'BRANCH_CODE_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.branches (organization_id, name, code, address, city, governorate, phone, eta_branch_code,
                                 building_number, is_main, created_by)
    VALUES (v_org, btrim(p_name), v_code, p_address, p_city, p_governorate, p_phone, p_eta_branch_code,
            NULLIF(btrim(p_building_number), ''), false, v_emp)
    RETURNING id INTO v_id;
    INSERT INTO public.cash_accounts (organization_id, branch_id, name, kind, created_by)
    VALUES (v_org, v_id, 'خزنة ' || btrim(p_name), 'safe', v_emp);
    IF (SELECT role FROM public.employees WHERE id = v_emp) <> 'OWNER' THEN
        INSERT INTO public.employee_branches (organization_id, employee_id, branch_id) VALUES (v_org, v_emp, v_id);
    END IF;
    PERFORM app.write_audit('branch.created', 'branch', v_id,
        p_after => (SELECT to_jsonb(b) FROM public.branches b WHERE id = v_id));
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'branches_code_key' THEN
        RAISE EXCEPTION 'BRANCH_CODE_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    RAISE;
END;
$$;

CREATE FUNCTION public.update_branch(p_branch_id uuid, p_name text, p_address text, p_city text, p_governorate text,
                                     p_phone text, p_eta_branch_code text, p_default_cash_account_id uuid,
                                     p_building_number text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_before public.branches%ROWTYPE;
BEGIN
    v_emp := app.require_permission('branch.manage');
    v_org := app.current_org_id();
    SELECT * INTO v_before FROM public.branches WHERE id = p_branch_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF NULLIF(btrim(p_name), '') IS NULL OR length(btrim(p_name)) > 100 THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF length(p_eta_branch_code) > 20 OR length(p_building_number) > 100 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.branches
       SET name = btrim(p_name), address = p_address, city = p_city, governorate = p_governorate, phone = p_phone,
           eta_branch_code = p_eta_branch_code, building_number = NULLIF(btrim(p_building_number), ''),
           default_cash_account_id = p_default_cash_account_id, updated_by = v_emp, updated_at = now()
     WHERE id = p_branch_id;
    PERFORM app.write_audit('branch.updated', 'branch', p_branch_id, p_before => to_jsonb(v_before),
        p_after => (SELECT to_jsonb(b) FROM public.branches b WHERE id = p_branch_id));
END;
$$;

REVOKE ALL ON FUNCTION public.create_branch(text, text, text, text, text, text, text, text),
    public.update_branch(uuid, text, text, text, text, text, text, uuid, text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_branch(text, text, text, text, text, text, text, text),
    public.update_branch(uuid, text, text, text, text, text, text, uuid, text)
    TO authenticated;

-- 2. Indexes -------------------------------------------------------------------------------------------

-- One fiscal row per sale and per return is already unique in the baseline
-- (fiscal_submissions_sale_idx, fiscal_submissions_return_idx).
CREATE UNIQUE INDEX fiscal_submissions_org_eta_uuid_idx ON public.fiscal_submissions (organization_id, eta_uuid)
    WHERE eta_uuid IS NOT NULL;
CREATE INDEX fiscal_submissions_device_open_idx ON public.fiscal_submissions (device_id, status)
    WHERE status IN ('pending', 'submitted');
CREATE INDEX fiscal_submissions_submission_idx ON public.fiscal_submissions (organization_id, eta_submission_uuid)
    WHERE eta_submission_uuid IS NOT NULL;

-- 3. Jobs and the sale trigger -------------------------------------------------------------------------

-- Queues one job per key (jobs_dedupe_idx: one queued or running job per type and key).
-- A job with this key that is still queued is pulled earlier when needed. One that is already
-- running may have read its work before this call, so one follow-up is queued behind it.
CREATE FUNCTION app.eta_enqueue(p_org uuid, p_job_type text, p_key text, p_payload jsonb,
                                p_delay_seconds integer DEFAULT 0)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_run_at timestamptz := now() + make_interval(secs => GREATEST(COALESCE(p_delay_seconds, 0), 0));
    v_key text := p_key; v_id uuid; i integer;
BEGIN
    FOR i IN 1..2 LOOP
        INSERT INTO public.jobs (organization_id, job_type, payload, dedupe_key, run_at)
        VALUES (p_org, p_job_type, COALESCE(p_payload, '{}'::jsonb), v_key, v_run_at)
        ON CONFLICT (job_type, dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('queued', 'running')
        DO NOTHING
        RETURNING id INTO v_id;
        IF v_id IS NOT NULL THEN
            RETURN;
        END IF;
        UPDATE public.jobs j SET run_at = v_run_at
        WHERE j.job_type = p_job_type AND j.dedupe_key = v_key AND j.status = 'queued' AND j.run_at > v_run_at;
        IF NOT EXISTS (SELECT 1 FROM public.jobs j
                       WHERE j.job_type = p_job_type AND j.dedupe_key = v_key AND j.status = 'running') THEN
            RETURN;
        END IF;
        v_key := p_key || '#next';
    END LOOP;
END;
$$;

-- A consumer sale in a shop with ETA on (settings enabled and the plan has the module) gets its
-- fiscal record and one eta.prepare job for its POS (for its branch when it has no POS: that
-- receipt is then blocked, see eta_block). B2B invoices are another ETA API (T04).
CREATE FUNCTION app.sales_eta_fiscal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_env public.eta_environment;
BEGIN
    IF NEW.is_b2b THEN
        RETURN NULL;
    END IF;
    SELECT s.environment INTO v_env FROM public.eta_settings s
    WHERE s.organization_id = NEW.organization_id AND s.is_enabled;
    IF NOT FOUND OR NOT app.org_has_module(NEW.organization_id, 'eta') THEN
        RETURN NULL;
    END IF;
    INSERT INTO public.fiscal_submissions (organization_id, branch_id, device_id, doc_type, sale_id, environment,
                                           internal_id, status, created_by)
    VALUES (NEW.organization_id, NEW.branch_id, NEW.device_id, 'b2c_receipt', NEW.id, v_env, NEW.number,
            'pending', NEW.created_by);
    PERFORM app.eta_enqueue(NEW.organization_id, 'eta.prepare',
        'eta.prepare:' || COALESCE(NEW.device_id, NEW.branch_id)::text,
        jsonb_build_object('device_id', NEW.device_id, 'branch_id', NEW.branch_id));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_sales_eta_fiscal AFTER INSERT ON public.sales
    FOR EACH ROW EXECUTE FUNCTION app.sales_eta_fiscal();

-- 4. Shop side -----------------------------------------------------------------------------------------

-- Stores a secret in Vault and returns its id: the stored one is replaced, a missing one created.
CREATE FUNCTION app.eta_put_secret(p_vault_id uuid, p_secret text, p_description text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_vault_id IS NOT NULL AND EXISTS (SELECT 1 FROM vault.secrets s WHERE s.id = p_vault_id) THEN
        PERFORM vault.update_secret(p_vault_id, p_secret);
        RETURN p_vault_id;
    END IF;
    RETURN vault.create_secret(p_secret, NULL, p_description);
END;
$$;

-- Never the secret: only whether one is stored.
CREATE FUNCTION app.eta_settings_json(p_org uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('environment', s.environment, 'client_id', s.client_id,
                              'has_client_secret', s.client_secret_vault_id IS NOT NULL,
                              'activity_code', s.activity_code, 'is_enabled', s.is_enabled,
                              'updated_at', s.updated_at)
    FROM public.eta_settings s WHERE s.organization_id = p_org
$$;

CREATE FUNCTION public.get_eta_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    PERFORM app.require_permission('org.settings_manage');
    v_org := app.current_org_id();
    RETURN COALESCE(app.eta_settings_json(v_org),
        jsonb_build_object('environment', 'preprod', 'client_id', NULL, 'has_client_secret', false,
                           'activity_code', NULL, 'is_enabled', false, 'updated_at', NULL));
END;
$$;

-- The shop's ETA connection. p_client_secret NULL keeps the stored secret. Turning ETA on needs
-- the client id, a secret and the activity code. The environment can't change while a receipt is
-- on its way (pending or submitted): that receipt would go to the wrong system.
CREATE FUNCTION public.set_eta_settings(p_environment public.eta_environment, p_client_id text,
                                        p_client_secret text DEFAULT NULL, p_activity_code text DEFAULT NULL,
                                        p_enabled boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.eta_settings; v_vault uuid; v_before jsonb;
    v_client text := NULLIF(btrim(p_client_id), '');
    v_activity text := NULLIF(btrim(p_activity_code), '');
BEGIN
    v_emp := app.require_permission('org.settings_manage');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    IF p_environment IS NULL OR p_enabled IS NULL OR length(v_client) > 100
       OR length(p_client_secret) NOT BETWEEN 1 AND 100 OR v_activity !~ '^[0-9A-Za-z]{1,10}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: ETA settings' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.eta_settings (organization_id) VALUES (v_org) ON CONFLICT (organization_id) DO NOTHING;
    SELECT * INTO v_old FROM public.eta_settings s WHERE s.organization_id = v_org FOR UPDATE;
    v_before := app.eta_settings_json(v_org);
    IF v_old.environment <> p_environment AND EXISTS (
        SELECT 1 FROM public.fiscal_submissions f
        WHERE f.organization_id = v_org AND f.status IN ('pending', 'submitted')) THEN
        RAISE EXCEPTION 'ETA_ENV_BUSY: receipts are still on their way to %', v_old.environment
            USING ERRCODE = 'P0001';
    END IF;

    v_vault := v_old.client_secret_vault_id;
    IF p_client_secret IS NOT NULL THEN
        v_vault := app.eta_put_secret(v_vault, p_client_secret, 'ETA client secret, shop ' || v_org::text);
    END IF;
    IF p_enabled AND (v_client IS NULL OR v_activity IS NULL OR v_vault IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: ETA needs the client id, the client secret and the activity code'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.eta_settings s
       SET environment = p_environment, client_id = v_client, client_secret_vault_id = v_vault,
           activity_code = v_activity, is_enabled = p_enabled, updated_by = v_emp, updated_at = now()
     WHERE s.organization_id = v_org;

    -- A POS has one receipt chain per ETA system: each POS goes on from the last receipt it
    -- prepared for this environment (the one no other receipt names as its previous), or starts.
    IF v_old.environment <> p_environment THEN
        UPDATE public.devices d
           SET eta_last_uuid = (
               SELECT f.eta_uuid FROM public.fiscal_submissions f
               WHERE f.organization_id = v_org AND f.device_id = d.id AND f.environment = p_environment
                 AND f.eta_uuid IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM public.fiscal_submissions g
                                 WHERE g.organization_id = v_org AND g.device_id = d.id
                                   AND g.environment = p_environment AND g.previous_uuid = f.eta_uuid)
               ORDER BY f.updated_at DESC LIMIT 1)
         WHERE d.organization_id = v_org;
    END IF;

    PERFORM app.write_audit('eta.settings_updated', 'eta_settings', v_org, v_before,
        app.eta_settings_json(v_org) || jsonb_build_object('client_secret_changed', p_client_secret IS NOT NULL),
        NULL, NULL,
        CASE WHEN v_old.environment <> p_environment OR v_old.is_enabled <> p_enabled
             THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN app.eta_settings_json(v_org);
END;
$$;

-- Never the key: only whether one is stored.
CREATE FUNCTION app.eta_device_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', d.id, 'name', d.name, 'branch_id', d.branch_id, 'branch_name', b.name,
                              'eta_serial', d.eta_serial, 'eta_os_version', d.eta_os_version,
                              'eta_model_framework', d.eta_model_framework, 'eta_status', d.eta_status,
                              'has_preshared_key', d.eta_preshared_key_vault_id IS NOT NULL,
                              'is_active', d.is_active)
    FROM public.devices d
    JOIN public.branches b ON b.id = d.branch_id AND b.organization_id = d.organization_id
    WHERE d.organization_id = p_org AND d.id = p_id
$$;

-- The POS devices of the caller's branches, for the devices screen (device.manage) and the
-- "test connection" picker of the ETA settings (org.settings_manage).
CREATE FUNCTION public.list_devices()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    IF app.has_permission('org.settings_manage') THEN
        PERFORM app.require_permission('org.settings_manage');
    ELSE
        PERFORM app.require_permission('device.manage');
    END IF;
    v_org := app.current_org_id();
    RETURN COALESCE((
        SELECT jsonb_agg(app.eta_device_json(v_org, d.id) ORDER BY b.name, d.name, d.id)
        FROM public.devices d
        JOIN public.branches b ON b.id = d.branch_id AND b.organization_id = d.organization_id
        WHERE d.organization_id = v_org AND d.archived_at IS NULL AND app.has_branch_access(d.branch_id)),
        '[]'::jsonb);
END;
$$;

-- A POS's ETA registration. p_preshared_key NULL keeps the stored key. 'active' needs the serial,
-- the OS version, the model framework and a key. A new serial is a new POS for the ETA: its
-- receipt chain starts again.
CREATE FUNCTION public.set_device_eta(p_device_id uuid, p_serial text, p_os_version text, p_model_framework text,
                                      p_preshared_key text DEFAULT NULL,
                                      p_status public.device_status DEFAULT 'unregistered')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.devices; v_vault uuid; v_before jsonb;
    v_serial text := NULLIF(btrim(p_serial), '');
    v_os text := NULLIF(btrim(p_os_version), '');
    v_model text := NULLIF(btrim(p_model_framework), '');
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    PERFORM app.require_module('eta');
    SELECT * INTO v_old FROM public.devices d
    WHERE d.id = p_device_id AND d.organization_id = v_org AND d.archived_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(v_old.branch_id);
    IF p_status IS NULL OR length(v_serial) > 100 OR length(v_os) > 50 OR length(v_model) > 10
       OR length(p_preshared_key) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: device ETA registration' USING ERRCODE = 'P0001';
    END IF;
    IF v_serial IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.devices d
        WHERE d.organization_id = v_org AND d.eta_serial = v_serial AND d.id <> p_device_id) THEN
        RAISE EXCEPTION 'DEVICE_SERIAL_TAKEN' USING ERRCODE = 'P0001';
    END IF;

    v_before := app.eta_device_json(v_org, p_device_id);
    v_vault := v_old.eta_preshared_key_vault_id;
    IF p_preshared_key IS NOT NULL THEN
        v_vault := app.eta_put_secret(v_vault, p_preshared_key, 'ETA POS pre-shared key, device ' || p_device_id::text);
    END IF;
    IF p_status = 'active' AND (v_serial IS NULL OR v_os IS NULL OR v_model IS NULL OR v_vault IS NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an active device needs its serial, OS version, model framework and key'
            USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.devices d
       SET eta_serial = v_serial, eta_os_version = v_os, eta_model_framework = v_model,
           eta_preshared_key_vault_id = v_vault, eta_status = p_status,
           eta_last_uuid = CASE WHEN d.eta_serial IS DISTINCT FROM v_serial THEN NULL ELSE d.eta_last_uuid END,
           updated_by = v_emp, updated_at = now()
     WHERE d.id = p_device_id;

    PERFORM app.write_audit('device.eta_updated', 'device', p_device_id, v_before,
        app.eta_device_json(v_org, p_device_id)
            || jsonb_build_object('preshared_key_changed', p_preshared_key IS NOT NULL),
        NULL, v_old.branch_id);
    RETURN app.eta_device_json(v_org, p_device_id);
END;
$$;

-- A failed (blocked) or rejected receipt goes back in the queue: built again when it has no
-- UUID yet, sent again as it is when it has one (a prepared receipt never changes).
CREATE FUNCTION public.retry_fiscal_submission(p_id uuid)
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

-- 5. Worker side (service role only) -------------------------------------------------------------------

CREATE FUNCTION public.eta_enqueue(p_org uuid, p_job_type text, p_key text, p_payload jsonb,
                                   p_delay_seconds integer DEFAULT 0)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_org IS NULL OR p_job_type NOT IN ('eta.prepare', 'eta.submit', 'eta.poll')
       OR p_key IS NULL OR length(p_key) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: ETA job' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.eta_enqueue(p_org, p_job_type, p_key, p_payload, p_delay_seconds);
END;
$$;

-- What is pending and not built yet for one POS, oldest first (issue time, then number), with
-- everything the receipt needs from the sale as it was stored, and the POS's chain tail read in
-- the same statement. p_device_id NULL: the branch's sales made without a POS.
-- Carries the buyer's national ID: never log the result.
CREATE FUNCTION public.eta_load_pending_for_device(p_device_id uuid, p_branch_id uuid DEFAULT NULL,
                                                   p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'last_uuid', (SELECT d.eta_last_uuid FROM public.devices d WHERE d.id = p_device_id),
        'rows', COALESCE((
            SELECT jsonb_agg(k.doc ORDER BY k.issued_at, k.number)
            FROM (
                SELECT s.issued_at, s.number, jsonb_build_object(
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
                        'is_active', d.is_active AND d.archived_at IS NULL) END) AS doc
                FROM public.fiscal_submissions f
                JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
                JOIN public.organizations o ON o.id = f.organization_id
                JOIN public.branches b ON b.id = f.branch_id AND b.organization_id = f.organization_id
                LEFT JOIN public.eta_settings es ON es.organization_id = f.organization_id
                LEFT JOIN public.customers c ON c.id = s.customer_id AND c.organization_id = f.organization_id
                LEFT JOIN public.devices d ON d.id = f.device_id AND d.organization_id = f.organization_id
                WHERE f.status = 'pending' AND f.eta_uuid IS NULL AND f.doc_type = 'b2c_receipt'
                  AND ((p_device_id IS NOT NULL AND f.device_id = p_device_id)
                       OR (p_device_id IS NULL AND p_branch_id IS NOT NULL AND f.device_id IS NULL
                           AND f.branch_id = p_branch_id))
                ORDER BY s.issued_at, s.number
                LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) k), '[]'::jsonb))
$$;

-- What the token call needs for one POS of one shop, read from Vault. NULL when the POS isn't the
-- shop's. Never log the result.
CREATE FUNCTION public.eta_credentials(p_org uuid, p_device uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'environment', s.environment, 'client_id', s.client_id,
        'client_secret', (SELECT v.decrypted_secret FROM vault.decrypted_secrets v
                          WHERE v.id = s.client_secret_vault_id),
        'pos_serial', d.eta_serial, 'pos_os_version', d.eta_os_version,
        'pos_model_framework', d.eta_model_framework,
        'preshared_key', (SELECT v.decrypted_secret FROM vault.decrypted_secrets v
                          WHERE v.id = d.eta_preshared_key_vault_id),
        'device_status', d.eta_status, 'device_active', d.is_active AND d.archived_at IS NULL)
    FROM public.devices d
    JOIN public.eta_settings s ON s.organization_id = d.organization_id
    WHERE d.id = p_device AND d.organization_id = p_org
$$;

-- Stores a built receipt and moves the POS chain, or changes nothing:
--   ALREADY_PREPARED  the receipt has its UUID (another worker built it): the UUID never changes
--   CHAIN_MOVED       the POS's last UUID is no longer the previousUUID this receipt was hashed
--                     with: the caller reads the chain again and builds the receipt again
-- The eta.submit job of the POS is queued with it.
CREATE FUNCTION public.eta_store_prepared(p_fiscal_id uuid, p_uuid text, p_previous_uuid text, p_payload jsonb,
                                          p_qr text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_f public.fiscal_submissions; v_prev text := COALESCE(p_previous_uuid, '');
BEGIN
    IF p_uuid IS NULL OR p_uuid !~ '^[0-9a-f]{64}$' OR v_prev !~ '^([0-9a-f]{64})?$' OR p_uuid = v_prev
       OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR NULLIF(p_qr, '') IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: prepared receipt' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.id = p_fiscal_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FISCAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status <> 'pending' OR v_f.eta_uuid IS NOT NULL THEN
        RAISE EXCEPTION 'ALREADY_PREPARED' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.device_id IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a receipt needs a POS' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.devices d SET eta_last_uuid = p_uuid
    WHERE d.id = v_f.device_id AND COALESCE(d.eta_last_uuid, '') = v_prev;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CHAIN_MOVED' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.fiscal_submissions f
       SET eta_uuid = p_uuid, previous_uuid = v_prev, qr_payload = p_qr,
           payload = COALESCE(f.payload, '{}'::jsonb) || p_payload,     -- keeps the deadline mark
           next_retry_at = NULL, last_error = NULL, updated_at = now()
     WHERE f.id = p_fiscal_id;
    PERFORM app.eta_enqueue(v_f.organization_id, 'eta.submit', 'eta.submit:' || v_f.device_id::text,
        jsonb_build_object('device_id', v_f.device_id));
END;
$$;

-- A receipt that can't be built because data is missing: 'failed', the reason starting with its
-- code (BLOCKED:NO_DEVICE, BLOCKED:ITEM_CODE, BLOCKED:SELLER_DATA, BLOCKED:BUYER_ID), no
-- automatic retry. true when this call blocked it (the caller alerts once).
CREATE FUNCTION public.eta_block(p_fiscal_id uuid, p_code text, p_message text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF p_code IS NULL OR p_code !~ '^BLOCKED:[A-Z_]{2,40}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: block code' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.fiscal_submissions f
       SET status = 'failed', last_error = left(p_code || ': ' || COALESCE(p_message, ''), 2000),
           next_retry_at = NULL, attempts = f.attempts + 1, updated_at = now()
     WHERE f.id = p_fiscal_id AND f.status = 'pending' AND f.eta_uuid IS NULL;
    RETURN FOUND;
END;
$$;

-- Takes the prepared receipts of one POS that are due, oldest first, for one send: each is
-- leased (next_retry_at moves p_lease_seconds ahead), so a second worker can't send it at the
-- same time, and marked as sent. A receipt that was marked before (`was_sent`) may already be
-- at the ETA: the worker looks it up by UUID before sending it again.
CREATE FUNCTION public.eta_claim_for_submit(p_device_id uuid, p_limit integer DEFAULT 50,
                                            p_lease_seconds integer DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
    WITH due AS (
        SELECT f.id, COALESCE(s.issued_at, f.created_at) AS issued_at, f.internal_id,
               COALESCE(f.payload ? 'sent', false) AS was_sent
        FROM public.fiscal_submissions f
        LEFT JOIN public.sales s ON s.id = f.sale_id AND s.organization_id = f.organization_id
        WHERE f.device_id = p_device_id AND f.status = 'pending' AND f.eta_uuid IS NOT NULL
          AND (f.next_retry_at IS NULL OR f.next_retry_at <= now())
        ORDER BY COALESCE(s.issued_at, f.created_at), f.internal_id
        LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500)
        FOR UPDATE OF f SKIP LOCKED
    ), leased AS (
        UPDATE public.fiscal_submissions f
           SET next_retry_at = now() + make_interval(secs => GREATEST(COALESCE(p_lease_seconds, 300), 1)),
               payload = f.payload || jsonb_build_object('sent', true), updated_at = now()
          FROM due WHERE f.id = due.id
        RETURNING f.id, f.organization_id, f.environment, f.internal_id, f.eta_uuid, f.attempts,
                  f.payload ->> 'receipt_json' AS receipt_json, due.issued_at, due.was_sent
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'fiscal_id', l.id, 'organization_id', l.organization_id, 'environment', l.environment,
               'internal_id', l.internal_id, 'uuid', l.eta_uuid, 'attempts', l.attempts,
               'receipt_json', l.receipt_json, 'was_sent', l.was_sent) ORDER BY l.issued_at, l.internal_id),
           '[]'::jsonb)
    INTO v_out FROM leased l;
    RETURN v_out;
END;
$$;

-- One status change of a receipt, by the worker. p_fields: last_error (a failed attempt: attempts
-- + 1), retry_in_seconds, eta_long_id, eta_submission_uuid, poll_in_seconds.
--   pending    a send that failed: stays pending, due again after retry_in_seconds (eta.submit queued)
--   submitted  the ETA has it: submitted_at, long id, submission (eta.poll queued)
--   accepted   Valid: accepted_at (the row is then frozen)
--   rejected   refused in the submit answer, or Invalid: the reason in last_error
-- A final receipt (accepted, cancelled) is left as it is and its status returned, so a repeated
-- poll is harmless.
CREATE FUNCTION public.eta_mark(p_fiscal_id uuid, p_status public.fiscal_status, p_fields jsonb DEFAULT '{}'::jsonb)
RETURNS public.fiscal_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_f public.fiscal_submissions;
    v_fields jsonb := COALESCE(p_fields, '{}'::jsonb);
    v_err text := NULLIF(left(v_fields ->> 'last_error', 2000), '');
    v_sub text := NULLIF(v_fields ->> 'eta_submission_uuid', '');
    v_retry integer; v_poll integer;
BEGIN
    v_retry := GREATEST(COALESCE((v_fields ->> 'retry_in_seconds')::integer, 0), 0);
    v_poll := GREATEST(COALESCE((v_fields ->> 'poll_in_seconds')::integer, 30), 0);
    SELECT * INTO v_f FROM public.fiscal_submissions f WHERE f.id = p_fiscal_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FISCAL_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_f.status IN ('accepted', 'cancelled') OR (v_f.status = 'rejected' AND p_status = 'rejected') THEN
        RETURN v_f.status;
    END IF;
    IF v_f.eta_uuid IS NULL OR NOT (
           (p_status = 'pending'   AND v_f.status = 'pending')
        OR (p_status = 'submitted' AND v_f.status IN ('pending', 'submitted'))
        OR (p_status = 'accepted'  AND v_f.status = 'submitted')
        OR (p_status = 'rejected'  AND v_f.status IN ('pending', 'submitted'))) THEN
        RAISE EXCEPTION 'FISCAL_BAD_TRANSITION: % to %', v_f.status, p_status USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.fiscal_submissions f
       SET status = p_status,
           attempts = f.attempts + CASE WHEN v_err IS NOT NULL THEN 1 ELSE 0 END,
           last_error = CASE WHEN p_status IN ('submitted', 'accepted') THEN NULL
                             ELSE COALESCE(v_err, f.last_error) END,
           next_retry_at = CASE WHEN p_status = 'pending' THEN now() + make_interval(secs => v_retry) END,
           eta_long_id = COALESCE(NULLIF(v_fields ->> 'eta_long_id', ''), f.eta_long_id),
           eta_submission_uuid = COALESCE(v_sub, f.eta_submission_uuid),
           submitted_at = CASE WHEN p_status = 'submitted' THEN COALESCE(f.submitted_at, now())
                               ELSE f.submitted_at END,
           accepted_at = CASE WHEN p_status = 'accepted' THEN now() END,
           updated_at = now()
     WHERE f.id = p_fiscal_id
    RETURNING * INTO v_f;

    IF p_status = 'pending' THEN
        PERFORM app.eta_enqueue(v_f.organization_id, 'eta.submit', 'eta.submit:' || v_f.device_id::text,
            jsonb_build_object('device_id', v_f.device_id), v_retry);
    ELSIF p_status = 'submitted' AND v_f.eta_submission_uuid IS NOT NULL THEN
        PERFORM app.eta_enqueue(v_f.organization_id, 'eta.poll', 'eta.poll:' || v_f.eta_submission_uuid || ':0',
            jsonb_build_object('submission_uuid', v_f.eta_submission_uuid, 'device_id', v_f.device_id, 'n', 0),
            v_poll);
    END IF;
    RETURN v_f.status;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: receipt fields' USING ERRCODE = 'P0001';
END;
$$;

-- The receipts of one submission that still wait for the ETA's answer.
CREATE FUNCTION public.eta_load_submitted(p_org uuid, p_submission_uuid text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('fiscal_id', f.id, 'uuid', f.eta_uuid,
                                                 'internal_id', f.internal_id) ORDER BY f.internal_id),
                    '[]'::jsonb)
    FROM public.fiscal_submissions f
    WHERE f.organization_id = p_org AND f.eta_submission_uuid = p_submission_uuid AND f.status = 'submitted'
$$;

-- The receipts of one POS still pending p_hours after their sale (the ETA takes a receipt for 24
-- hours), each returned ONCE: the mark is written by the same statement that returns the row.
CREATE FUNCTION public.eta_claim_deadline_alerts(p_device_id uuid, p_hours integer DEFAULT 20,
                                                 p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_out jsonb;
BEGIN
    WITH late AS (
        UPDATE public.fiscal_submissions f
           SET payload = COALESCE(f.payload, '{}'::jsonb) || jsonb_build_object('deadline_alerted_at', p_now),
               updated_at = now()
          FROM public.sales s
         WHERE s.id = f.sale_id AND s.organization_id = f.organization_id
           AND f.device_id = p_device_id AND f.status = 'pending'
           AND s.issued_at < p_now - make_interval(hours => GREATEST(COALESCE(p_hours, 20), 1))
           AND NOT (COALESCE(f.payload, '{}'::jsonb) ? 'deadline_alerted_at')
        RETURNING f.id, f.organization_id, f.internal_id, s.issued_at
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('fiscal_id', l.id, 'organization_id', l.organization_id,
                                                 'internal_id', l.internal_id, 'issued_at', l.issued_at)
                              ORDER BY l.issued_at), '[]'::jsonb)
    INTO v_out FROM late l;
    RETURN v_out;
END;
$$;

-- What the sale answer and the reprint show of a sale's receipt, and the POS and branch it is
-- prepared for: NULL when the sale has none (ETA off, or B2B). The caller has already been
-- allowed to read the sale (post_sale, get_sale).
CREATE FUNCTION public.eta_sale_status(p_org uuid, p_sale_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('status', f.status, 'uuid', f.eta_uuid, 'qr_payload', f.qr_payload,
                              'last_error_code', substring(f.last_error FROM '^(BLOCKED:[A-Z_]+|[A-Z][A-Z_]+)'),
                              'device_id', f.device_id, 'branch_id', f.branch_id)
    FROM public.fiscal_submissions f
    WHERE f.organization_id = p_org AND f.sale_id = p_sale_id
$$;

-- 6. Grants --------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.eta_enqueue(uuid, text, text, jsonb, integer), app.sales_eta_fiscal(),
    app.eta_put_secret(uuid, text, text), app.eta_settings_json(uuid), app.eta_device_json(uuid, uuid)
    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_eta_settings(),
    public.set_eta_settings(public.eta_environment, text, text, text, boolean), public.list_devices(),
    public.set_device_eta(uuid, text, text, text, text, public.device_status),
    public.retry_fiscal_submission(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_eta_settings(),
    public.set_eta_settings(public.eta_environment, text, text, text, boolean), public.list_devices(),
    public.set_device_eta(uuid, text, text, text, text, public.device_status),
    public.retry_fiscal_submission(uuid)
    TO authenticated;

REVOKE ALL ON FUNCTION public.eta_enqueue(uuid, text, text, jsonb, integer),
    public.eta_load_pending_for_device(uuid, uuid, integer), public.eta_credentials(uuid, uuid),
    public.eta_store_prepared(uuid, text, text, jsonb, text), public.eta_block(uuid, text, text),
    public.eta_claim_for_submit(uuid, integer, integer), public.eta_mark(uuid, public.fiscal_status, jsonb),
    public.eta_load_submitted(uuid, text), public.eta_claim_deadline_alerts(uuid, integer, timestamptz),
    public.eta_sale_status(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.eta_enqueue(uuid, text, text, jsonb, integer),
    public.eta_load_pending_for_device(uuid, uuid, integer), public.eta_credentials(uuid, uuid),
    public.eta_store_prepared(uuid, text, text, jsonb, text), public.eta_block(uuid, text, text),
    public.eta_claim_for_submit(uuid, integer, integer), public.eta_mark(uuid, public.fiscal_status, jsonb),
    public.eta_load_submitted(uuid, text), public.eta_claim_deadline_alerts(uuid, integer, timestamptz),
    public.eta_sale_status(uuid, uuid)
    TO service_role;
