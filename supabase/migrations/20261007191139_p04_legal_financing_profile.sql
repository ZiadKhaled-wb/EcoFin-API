ALTER TABLE public.organizations
    ADD COLUMN consumer_finance_legal_status text
        CHECK (consumer_finance_legal_status IS NULL OR length(consumer_finance_legal_status) <= 500);

-- The legal/tax identifiers are maintained only through the dedicated profile permission.
ALTER FUNCTION public.update_org_settings(jsonb) RENAME TO update_org_settings_p03;
REVOKE ALL ON FUNCTION public.update_org_settings_p03(jsonb) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.update_org_settings(p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    PERFORM app.require_permission('org.settings_manage');
    IF p_changes ? 'tax_registration_no' THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: tax_registration_no' USING ERRCODE = 'P0001';
    END IF;
    PERFORM public.update_org_settings_p03(p_changes);
END;
$$;
REVOKE ALL ON FUNCTION public.update_org_settings(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_org_settings(jsonb) TO authenticated;

CREATE FUNCTION public.get_shop_profile()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    RETURN (SELECT jsonb_build_object(
        'legal_name', o.legal_name,
        'commercial_register', o.commercial_register,
        'tax_registration_no', o.tax_registration_no,
        'consumer_finance_legal_status', o.consumer_finance_legal_status,
        'creditor_model', o.creditor_model,
        'installments_enabled', o.installments_enabled,
        'updated_at', o.updated_at)
        FROM public.organizations o WHERE o.id = v_org);
END;
$$;
REVOKE ALL ON FUNCTION public.get_shop_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shop_profile() TO authenticated;

CREATE FUNCTION public.update_org_profile(p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_emp uuid;
    v_org uuid;
    v_before jsonb;
    v_after jsonb;
    v_audit_before jsonb;
    v_audit_after jsonb;
    v_key text;
    v_keys text[] := ARRAY['legal_name', 'commercial_register', 'tax_registration_no',
        'consumer_finance_legal_status', 'installments_enabled'];
BEGIN
    v_emp := app.require_permission('org.profile_manage');
    v_org := app.current_org_id();
    IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' THEN
        RAISE EXCEPTION 'SETTINGS_INVALID: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(p_changes) k WHERE k <> ALL (v_keys) LIMIT 1;
    IF v_key IS NOT NULL THEN RAISE EXCEPTION 'SETTINGS_INVALID: %', v_key USING ERRCODE = 'P0001'; END IF;
    SELECT jsonb_build_object('legal_name', legal_name, 'commercial_register', commercial_register,
        'tax_registration_no', tax_registration_no,
        'consumer_finance_legal_status', consumer_finance_legal_status,
        'installments_enabled', installments_enabled)
    INTO v_before FROM public.organizations WHERE id = v_org FOR UPDATE;
    IF v_before IS NULL THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;

    IF p_changes ? 'legal_name' AND jsonb_typeof(p_changes -> 'legal_name') NOT IN ('string', 'null')
       OR p_changes ? 'commercial_register' AND jsonb_typeof(p_changes -> 'commercial_register') NOT IN ('string', 'null')
       OR p_changes ? 'tax_registration_no' AND jsonb_typeof(p_changes -> 'tax_registration_no') NOT IN ('string', 'null')
       OR p_changes ? 'consumer_finance_legal_status' AND jsonb_typeof(p_changes -> 'consumer_finance_legal_status') NOT IN ('string', 'null')
       OR p_changes ? 'installments_enabled' AND jsonb_typeof(p_changes -> 'installments_enabled') <> 'boolean' THEN
        RAISE EXCEPTION 'SETTINGS_INVALID' USING ERRCODE = 'P0001';
    END IF;
    IF p_changes ? 'legal_name' AND length(NULLIF(btrim(p_changes ->> 'legal_name'), '')) > 200
       OR p_changes ? 'commercial_register' AND length(NULLIF(btrim(p_changes ->> 'commercial_register'), '')) > 50
       OR p_changes ? 'tax_registration_no' AND length(NULLIF(btrim(p_changes ->> 'tax_registration_no'), '')) > 50
       OR p_changes ? 'consumer_finance_legal_status' AND length(NULLIF(btrim(p_changes ->> 'consumer_finance_legal_status'), '')) > 500 THEN
        RAISE EXCEPTION 'SETTINGS_INVALID' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.organizations SET
        legal_name = CASE WHEN p_changes ? 'legal_name' THEN NULLIF(btrim(p_changes ->> 'legal_name'), '') ELSE legal_name END,
        commercial_register = CASE WHEN p_changes ? 'commercial_register' THEN NULLIF(btrim(p_changes ->> 'commercial_register'), '') ELSE commercial_register END,
        tax_registration_no = CASE WHEN p_changes ? 'tax_registration_no' THEN NULLIF(btrim(p_changes ->> 'tax_registration_no'), '') ELSE tax_registration_no END,
        consumer_finance_legal_status = CASE WHEN p_changes ? 'consumer_finance_legal_status' THEN NULLIF(btrim(p_changes ->> 'consumer_finance_legal_status'), '') ELSE consumer_finance_legal_status END,
        installments_enabled = CASE WHEN p_changes ? 'installments_enabled' THEN (p_changes ->> 'installments_enabled')::boolean ELSE installments_enabled END
    WHERE id = v_org;
    SELECT jsonb_build_object('legal_name', legal_name, 'commercial_register', commercial_register,
        'tax_registration_no', tax_registration_no,
        'consumer_finance_legal_status', consumer_finance_legal_status,
        'installments_enabled', installments_enabled)
    INTO v_after FROM public.organizations WHERE id = v_org;
    SELECT jsonb_object_agg(k, v_before -> k), jsonb_object_agg(k, v_after -> k)
    INTO v_audit_before, v_audit_after
    FROM jsonb_object_keys(v_before) k
    WHERE (v_before -> k) IS DISTINCT FROM (v_after -> k);
    IF v_audit_after IS NOT NULL THEN
        PERFORM app.write_audit('org.profile_updated', 'organization', v_org,
            p_before => v_audit_before, p_after => v_audit_after);
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.update_org_profile(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_org_profile(jsonb) TO authenticated;

-- Enforce the installment switch at the contract boundary and snapshot the current creditor.
CREATE FUNCTION app.contract_creditor_for(p_org uuid)
RETURNS public.creditor_model LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_enabled boolean; v_creditor public.creditor_model;
BEGIN
    SELECT installments_enabled, creditor_model INTO v_enabled, v_creditor
    FROM public.organizations WHERE id = p_org FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORG_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
    IF NOT v_enabled THEN RAISE EXCEPTION 'INSTALLMENTS_DISABLED' USING ERRCODE = 'P0001'; END IF;
    RETURN v_creditor;
END;
$$;
REVOKE ALL ON FUNCTION app.contract_creditor_for(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION app.set_contract_creditor()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    NEW.creditor := app.contract_creditor_for(NEW.organization_id);
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION app.set_contract_creditor() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER contracts_profile_guard
    BEFORE INSERT ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION app.set_contract_creditor();
