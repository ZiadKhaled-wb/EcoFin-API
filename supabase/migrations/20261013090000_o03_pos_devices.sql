-- O03 POS devices (EC-146, D68).
--
-- A shop registers its POS computers (device.manage) and pairs each browser once with a one-time
-- code. The browser then holds a device token; the API hashes it, resolves it here
-- (public.resolve_device) and only then sends x-device-id to the database. A client-sent
-- x-device-id never reaches the database, so app.current_device_id() can be trusted.
-- Opening a shift needs that device; a sale takes its device from its shift (a trigger: the sale
-- function is not touched), and T02's fiscal trigger then sees it.
-- Only SHA-256 hashes of the pairing code and of the device token are stored, in columns
-- `authenticated` can't read.

-- 1. Columns -------------------------------------------------------------------------------------------

ALTER TABLE public.devices
    ADD COLUMN pairing_code_hash  text,          -- SHA-256 of the one-time code; cleared when used
    ADD COLUMN pairing_expires_at timestamptz,
    ADD COLUMN token_hash         text,          -- SHA-256 of the device token; NULL = not paired
    ADD COLUMN paired_at          timestamptz,
    ADD COLUMN paired_by          uuid;

CREATE UNIQUE INDEX devices_token_hash_idx ON public.devices (token_hash) WHERE token_hash IS NOT NULL;
CREATE UNIQUE INDEX devices_branch_name_idx ON public.devices (organization_id, branch_id, lower(name))
    WHERE archived_at IS NULL;

-- devices has column grants (T02): the two hashes are not granted.
GRANT SELECT (pairing_expires_at, paired_at, paired_by) ON public.devices TO authenticated;

-- 2. The device of this request ------------------------------------------------------------------------

-- The x-device-id header's device, only when it is an active, unarchived device of the caller's
-- shop. The API sets that header itself, after resolving the device token.
CREATE FUNCTION app.current_device_id()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_id uuid; v_org uuid := app.current_org_id();
BEGIN
    IF v_org IS NULL THEN
        RETURN NULL;
    END IF;
    BEGIN
        v_id := NULLIF(NULLIF(current_setting('request.headers', true), '')::jsonb ->> 'x-device-id', '')::uuid;
    EXCEPTION WHEN others THEN
        RETURN NULL;
    END;
    RETURN (SELECT d.id FROM public.devices d
            WHERE d.id = v_id AND d.organization_id = v_org AND d.is_active AND d.archived_at IS NULL);
END;
$$;

-- T02's device answer, with the pairing state (never a hash).
CREATE OR REPLACE FUNCTION app.eta_device_json(p_org uuid, p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', d.id, 'name', d.name, 'branch_id', d.branch_id, 'branch_name', b.name,
                              'eta_serial', d.eta_serial, 'eta_os_version', d.eta_os_version,
                              'eta_model_framework', d.eta_model_framework, 'eta_status', d.eta_status,
                              'has_preshared_key', d.eta_preshared_key_vault_id IS NOT NULL,
                              'is_active', d.is_active, 'paired', d.token_hash IS NOT NULL,
                              'paired_at', d.paired_at, 'last_seen_at', d.last_seen_at)
    FROM public.devices d
    JOIN public.branches b ON b.id = d.branch_id AND b.organization_id = d.organization_id
    WHERE d.organization_id = p_org AND d.id = p_id
$$;

-- The list now shows inactive devices too (they can be reactivated).
CREATE OR REPLACE FUNCTION public.list_devices()
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

-- 3. Managing devices ----------------------------------------------------------------------------------

-- The caller's device row, locked; another shop's id is DEVICE_NOT_FOUND.
CREATE FUNCTION app.device_for_write(p_org uuid, p_device_id uuid)
RETURNS public.devices LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_d public.devices;
BEGIN
    SELECT * INTO v_d FROM public.devices d
    WHERE d.id = p_device_id AND d.organization_id = p_org AND d.archived_at IS NULL FOR UPDATE;
    IF NOT FOUND OR NOT app.has_branch_access(v_d.branch_id) THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_d;
END;
$$;

CREATE FUNCTION app.device_name(p_org uuid, p_branch uuid, p_name text, p_except uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_name text := btrim(p_name);
BEGIN
    IF v_name IS NULL OR length(v_name) NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: device name' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.devices d
               WHERE d.organization_id = p_org AND d.branch_id = p_branch AND lower(d.name) = lower(v_name)
                 AND d.archived_at IS NULL AND d.id IS DISTINCT FROM p_except) THEN
        RAISE EXCEPTION 'DEVICE_NAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_name;
END;
$$;

CREATE FUNCTION public.create_device(p_branch_id uuid, p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid; v_name text;
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    -- One at a time per shop: the name check and the plan limit can't race.
    PERFORM 1 FROM public.organizations o WHERE o.id = v_org FOR UPDATE;
    v_name := app.device_name(v_org, p_branch_id, p_name, NULL);
    INSERT INTO public.devices (organization_id, branch_id, name, created_by, updated_by)
    VALUES (v_org, p_branch_id, v_name, v_emp, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('device.created', 'device', v_id, NULL,
        jsonb_build_object('name', v_name, 'branch_id', p_branch_id), NULL, p_branch_id);
    RETURN v_id;
END;
$$;

-- p_name / p_branch_id NULL: unchanged. A move is refused while the device has an open shift.
CREATE FUNCTION public.update_device(p_device_id uuid, p_name text DEFAULT NULL, p_branch_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices; v_branch uuid; v_name text;
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    v_d := app.device_for_write(v_org, p_device_id);
    v_branch := COALESCE(p_branch_id, v_d.branch_id);
    IF v_branch <> v_d.branch_id THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = v_branch AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        PERFORM app.require_branch_access(v_branch);
        IF EXISTS (SELECT 1 FROM public.shifts s
                   WHERE s.organization_id = v_org AND s.device_id = p_device_id AND s.status = 'open') THEN
            RAISE EXCEPTION 'DEVICE_HAS_OPEN_SHIFT' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    v_name := app.device_name(v_org, v_branch, COALESCE(p_name, v_d.name), p_device_id);
    UPDATE public.devices d SET name = v_name, branch_id = v_branch, updated_by = v_emp, updated_at = now()
    WHERE d.id = p_device_id;
    PERFORM app.write_audit('device.updated', 'device', p_device_id,
        jsonb_build_object('name', v_d.name, 'branch_id', v_d.branch_id),
        jsonb_build_object('name', v_name, 'branch_id', v_branch), NULL, v_branch);
    RETURN app.eta_device_json(v_org, p_device_id);
END;
$$;

-- Deactivating needs a reason, is refused with an open shift, and unpairs. Reactivating goes
-- through the plan limit (P05 trigger).
CREATE FUNCTION public.set_device_active(p_device_id uuid, p_active boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices; v_reason text := NULLIF(btrim(p_reason), '');
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    IF p_active IS NULL OR length(v_reason) > 200 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: device active' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.organizations o WHERE o.id = v_org FOR UPDATE;
    v_d := app.device_for_write(v_org, p_device_id);
    IF v_d.is_active = p_active THEN
        RETURN jsonb_build_object('id', p_device_id, 'is_active', p_active);
    END IF;
    IF NOT p_active THEN
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.shifts s
                   WHERE s.organization_id = v_org AND s.device_id = p_device_id AND s.status = 'open') THEN
            RAISE EXCEPTION 'DEVICE_HAS_OPEN_SHIFT' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.devices d
           SET is_active = false, token_hash = NULL, paired_at = NULL, paired_by = NULL,
               pairing_code_hash = NULL, pairing_expires_at = NULL, updated_by = v_emp, updated_at = now()
         WHERE d.id = p_device_id;
    ELSE
        UPDATE public.devices d SET is_active = true, updated_by = v_emp, updated_at = now()
        WHERE d.id = p_device_id;
    END IF;
    PERFORM app.write_audit(CASE WHEN p_active THEN 'device.reactivated' ELSE 'device.deactivated' END,
        'device', p_device_id, jsonb_build_object('is_active', v_d.is_active),
        jsonb_build_object('is_active', p_active, 'was_paired', v_d.token_hash IS NOT NULL), v_reason,
        v_d.branch_id, CASE WHEN p_active THEN 'info' ELSE 'warning' END::public.audit_severity);
    RETURN jsonb_build_object('id', p_device_id, 'is_active', p_active);
END;
$$;

-- 4. Pairing -------------------------------------------------------------------------------------------

-- The API made the code; only its hash arrives here. A new code replaces an unused older one.
CREATE FUNCTION public.create_device_pairing_code(p_device_id uuid, p_code_hash text, p_expires_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices;
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    v_d := app.device_for_write(v_org, p_device_id);
    IF p_code_hash IS NULL OR p_code_hash !~ '^[0-9a-f]{64}$' OR p_expires_at IS NULL
       OR p_expires_at <= now() OR p_expires_at > now() + interval '15 minutes 5 seconds' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: pairing code' USING ERRCODE = 'P0001';
    END IF;
    IF NOT v_d.is_active THEN
        RAISE EXCEPTION 'DEVICE_INVALID: the device is not active' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.devices d
       SET pairing_code_hash = p_code_hash, pairing_expires_at = p_expires_at, updated_by = v_emp, updated_at = now()
     WHERE d.id = p_device_id;
    PERFORM app.write_audit('device.pairing_code_created', 'device', p_device_id, NULL,
        jsonb_build_object('expires_at', p_expires_at), NULL, v_d.branch_id);
    RETURN jsonb_build_object('id', p_device_id, 'expires_at', p_expires_at);
END;
$$;

-- An employee of the same shop (shift.operate or device.manage) turns a code into a paired
-- device. Every failure is PAIRING_CODE_INVALID: wrong, expired, used, another shop's, a device
-- that is not active or in a branch the caller can't use. Pairing again replaces the token.
CREATE FUNCTION public.pair_device(p_code_hash text, p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices; v_branch public.branches;
BEGIN
    IF app.has_permission('shift.operate') THEN
        v_emp := app.require_permission('shift.operate');
    ELSE
        v_emp := app.require_permission('device.manage');
    END IF;
    v_org := app.current_org_id();
    IF p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: device token' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_d FROM public.devices d
    WHERE d.organization_id = v_org AND d.pairing_code_hash = p_code_hash AND p_code_hash ~ '^[0-9a-f]{64}$'
    FOR UPDATE;
    IF FOUND THEN
        SELECT * INTO v_branch FROM public.branches b WHERE b.id = v_d.branch_id AND b.organization_id = v_org;
    END IF;
    IF v_d.id IS NULL OR v_d.pairing_expires_at IS NULL OR v_d.pairing_expires_at <= now()
       OR NOT v_d.is_active OR v_d.archived_at IS NOT NULL OR NOT v_branch.is_active
       OR NOT app.has_branch_access(v_d.branch_id) THEN
        RAISE EXCEPTION 'PAIRING_CODE_INVALID' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.devices d
       SET token_hash = p_token_hash, paired_at = now(), paired_by = v_emp,
           pairing_code_hash = NULL, pairing_expires_at = NULL, updated_by = v_emp, updated_at = now()
     WHERE d.id = v_d.id;
    PERFORM app.write_audit('device.paired', 'device', v_d.id, NULL,
        jsonb_build_object('replaced_pairing', v_d.token_hash IS NOT NULL), NULL, v_d.branch_id,
        CASE WHEN v_d.token_hash IS NOT NULL THEN 'warning' ELSE 'info' END::public.audit_severity);
    RETURN jsonb_build_object('device_id', v_d.id, 'name', v_d.name, 'branch_id', v_d.branch_id,
                              'branch_name', v_branch.name);
END;
$$;

CREATE FUNCTION public.unpair_device(p_device_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_d public.devices;
BEGIN
    v_emp := app.require_permission('device.manage');
    v_org := app.current_org_id();
    v_d := app.device_for_write(v_org, p_device_id);
    UPDATE public.devices d
       SET token_hash = NULL, paired_at = NULL, paired_by = NULL, pairing_code_hash = NULL,
           pairing_expires_at = NULL, updated_by = v_emp, updated_at = now()
     WHERE d.id = p_device_id;
    PERFORM app.write_audit('device.unpaired', 'device', p_device_id, NULL,
        jsonb_build_object('was_paired', v_d.token_hash IS NOT NULL), NULL, v_d.branch_id, 'warning');
    RETURN jsonb_build_object('id', p_device_id, 'paired', false);
END;
$$;

-- The device a token hash belongs to, for any employee of that device's shop: active device,
-- active branch. NULL otherwise. last_seen_at moves at most once every 5 minutes.
CREATE FUNCTION public.resolve_device(p_token_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid := app.current_org_id(); v_out jsonb; v_id uuid; v_seen timestamptz;
BEGIN
    IF v_org IS NULL OR p_token_hash IS NULL OR p_token_hash !~ '^[0-9a-f]{64}$' THEN
        RETURN NULL;
    END IF;
    SELECT d.id, d.last_seen_at,
           jsonb_build_object('device_id', d.id, 'name', d.name, 'branch_id', d.branch_id, 'branch_name', b.name)
    INTO v_id, v_seen, v_out
    FROM public.devices d
    JOIN public.branches b ON b.id = d.branch_id AND b.organization_id = d.organization_id
    WHERE d.organization_id = v_org AND d.token_hash = p_token_hash AND d.is_active
      AND d.archived_at IS NULL AND b.is_active;
    IF v_id IS NOT NULL AND (v_seen IS NULL OR v_seen < now() - interval '5 minutes') THEN
        UPDATE public.devices d SET last_seen_at = now() WHERE d.id = v_id;
    END IF;
    RETURN v_out;
END;
$$;

-- 5. Shifts need the device ----------------------------------------------------------------------------

-- K02's open_shift, unchanged but for the device: it is the paired device of this request
-- (DEVICE_REQUIRED without one), it must be in the shift's branch (DEVICE_BRANCH_MISMATCH), and
-- p_device_id, when sent, must be that same device (DEVICE_MISMATCH).
CREATE OR REPLACE FUNCTION public.open_shift(p_branch_id uuid, p_opening_float text, p_idempotency_key text,
                                             p_vault_id uuid DEFAULT NULL, p_device_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_s public.shifts; v_float numeric(18,2); v_vault public.cash_accounts;
    v_drawer uuid; v_transfer uuid; v_device uuid;
BEGIN
    v_emp := app.require_permission('shift.operate');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_s FROM public.shifts s WHERE s.organization_id = v_org AND s.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.shift_json(v_org, v_s.id, true);          -- a repeat changes nothing
    END IF;

    IF p_branch_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_branch_id);
    IF p_opening_float IS NULL OR p_opening_float !~ '^\d{1,16}(\.\d{1,2})?$' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: opening_float' USING ERRCODE = 'P0001';
    END IF;
    v_float := p_opening_float::numeric(18,2);
    IF (v_float > 0) <> (p_vault_id IS NOT NULL) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: a float needs the safe it comes from' USING ERRCODE = 'P0001';
    END IF;
    -- O03: the paired device of this request.
    v_device := app.current_device_id();
    IF v_device IS NULL THEN
        RAISE EXCEPTION 'DEVICE_REQUIRED: pair this computer as a POS device first' USING ERRCODE = 'P0001';
    END IF;
    IF p_device_id IS NOT NULL AND p_device_id <> v_device THEN
        RAISE EXCEPTION 'DEVICE_MISMATCH' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.devices d WHERE d.id = v_device AND d.branch_id = p_branch_id) THEN
        RAISE EXCEPTION 'DEVICE_BRANCH_MISMATCH' USING ERRCODE = 'P0001';
    END IF;
    -- The employee row is locked: two opens by one cashier run one after the other.
    PERFORM 1 FROM public.employees e WHERE e.id = v_emp AND e.organization_id = v_org FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.shifts s
               WHERE s.organization_id = v_org AND s.employee_id = v_emp AND s.status = 'open') THEN
        RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: close your open shift first' USING ERRCODE = 'P0001';
    END IF;
    PERFORM 1 FROM public.devices d WHERE d.id = v_device FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.shifts s
               WHERE s.organization_id = v_org AND s.device_id = v_device AND s.status = 'open') THEN
        RAISE EXCEPTION 'SHIFT_ALREADY_OPEN: this device has an open shift' USING ERRCODE = 'P0001';
    END IF;
    IF v_float > 0 THEN
        v_vault := app.shift_vault(v_org, p_vault_id, p_branch_id);
    END IF;
    v_drawer := app.shift_drawer(v_org, v_emp, p_branch_id);

    INSERT INTO public.shifts (organization_id, number, branch_id, device_id, employee_id, drawer_account_id,
                               opening_float, status, idempotency_key, created_by, updated_by)
    VALUES (v_org, app.next_document_number(v_org, p_branch_id, 'shift'), p_branch_id, v_device, v_emp,
            v_drawer, v_float, 'open', p_idempotency_key, v_emp, v_emp)
    RETURNING * INTO v_s;
    IF v_float > 0 THEN
        v_transfer := app.shift_transfer(v_org, v_emp, v_s, v_vault, v_float, true, v_s.number,
                                         'system:shift-open:' || v_s.id);
    END IF;

    PERFORM app.write_audit('shift.opened', 'shift', v_s.id, NULL,
        jsonb_build_object('number', v_s.number, 'opening_float', v_float::text, 'vault_id', p_vault_id,
                           'device_id', v_device, 'drawer_account_id', v_drawer, 'transfer_id', v_transfer),
        NULL, p_branch_id);
    RETURN app.shift_json(v_org, v_s.id, true);
END;
$$;

-- 6. A sale's device is its shift's --------------------------------------------------------------------

CREATE FUNCTION app.sales_device_from_shift()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_device uuid;
BEGIN
    IF NEW.shift_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.device_id INTO v_device FROM public.shifts s
    WHERE s.id = NEW.shift_id AND s.organization_id = NEW.organization_id;
    IF NEW.device_id IS NOT NULL AND NEW.device_id IS DISTINCT FROM v_device THEN
        RAISE EXCEPTION 'DEVICE_MISMATCH: a sale is made on its shift''s device' USING ERRCODE = 'P0001';
    END IF;
    NEW.device_id := v_device;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_sales_a_device BEFORE INSERT ON public.sales
    FOR EACH ROW EXECUTE FUNCTION app.sales_device_from_shift();

-- 7. Grants --------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.current_device_id(), app.device_for_write(uuid, uuid),
    app.device_name(uuid, uuid, text, uuid), app.sales_device_from_shift()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_device(uuid, text), public.update_device(uuid, text, uuid),
    public.set_device_active(uuid, boolean, text),
    public.create_device_pairing_code(uuid, text, timestamptz), public.pair_device(text, text),
    public.unpair_device(uuid), public.resolve_device(text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_device(uuid, text), public.update_device(uuid, text, uuid),
    public.set_device_active(uuid, boolean, text),
    public.create_device_pairing_code(uuid, text, timestamptz), public.pair_device(text, text),
    public.unpair_device(uuid), public.resolve_device(text)
    TO authenticated;
