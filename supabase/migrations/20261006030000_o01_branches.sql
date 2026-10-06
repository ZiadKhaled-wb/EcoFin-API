-- O01: tenant branch management and validated default safes.
ALTER TABLE public.branches ADD COLUMN default_cash_account_id uuid;
ALTER TABLE public.branches ADD CONSTRAINT branches_default_cash_account_fk FOREIGN KEY(default_cash_account_id,organization_id) REFERENCES public.cash_accounts(id,organization_id);
CREATE FUNCTION app.validate_branch_vault() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.default_cash_account_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.cash_accounts WHERE id=NEW.default_cash_account_id AND organization_id=NEW.organization_id AND branch_id=NEW.id AND kind='safe' AND is_active) THEN RAISE EXCEPTION 'VAULT_INVALID' USING ERRCODE='P0001'; END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION app.fill_branch_vault() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.kind='safe' AND NEW.is_active THEN UPDATE public.branches SET default_cash_account_id=NEW.id WHERE id=NEW.branch_id AND organization_id=NEW.organization_id AND default_cash_account_id IS NULL; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION app.validate_branch_vault(),app.fill_branch_vault() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER branches_validate_vault BEFORE INSERT OR UPDATE OF default_cash_account_id ON public.branches FOR EACH ROW EXECUTE FUNCTION app.validate_branch_vault();
CREATE TRIGGER cash_accounts_fill_vault AFTER INSERT ON public.cash_accounts FOR EACH ROW EXECUTE FUNCTION app.fill_branch_vault();
UPDATE public.branches b SET default_cash_account_id=s.id FROM (SELECT branch_id,organization_id,(array_agg(id))[1] id FROM public.cash_accounts WHERE kind='safe' AND is_active GROUP BY branch_id,organization_id HAVING count(*)=1)s WHERE b.id=s.branch_id AND b.organization_id=s.organization_id AND b.default_cash_account_id IS NULL;

CREATE OR REPLACE FUNCTION app.require_branch_access(p_branch_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF EXISTS(SELECT 1 FROM public.branches WHERE id=p_branch_id AND NOT is_active) THEN
        RAISE EXCEPTION 'BRANCH_INACTIVE: %', p_branch_id USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_branch_access(p_branch_id) THEN
        RAISE EXCEPTION 'BRANCH_DENIED: %', p_branch_id USING ERRCODE = '42501';
    END IF;
END;
$$;

CREATE FUNCTION public.create_branch(p_name text,p_code text,p_address text,p_city text,p_governorate text,p_phone text,p_eta_branch_code text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid; v_org uuid; v_id uuid; v_code text; v_constraint text;
BEGIN
 v_emp:=app.require_permission('branch.manage'); v_org:=app.current_org_id();
 IF NULLIF(btrim(p_name),'') IS NULL OR length(btrim(p_name))>100 THEN RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE='P0001'; END IF;
 v_code:=upper(btrim(p_code));
 IF v_code IS NULL OR v_code !~ '^[A-Z0-9]{1,6}$' THEN RAISE EXCEPTION 'BRANCH_CODE_INVALID' USING ERRCODE='P0001'; END IF;
 IF length(p_eta_branch_code)>20 THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 PERFORM 1 FROM public.organizations WHERE id=v_org FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.branches WHERE organization_id=v_org AND code=v_code) THEN RAISE EXCEPTION 'BRANCH_CODE_TAKEN' USING ERRCODE='P0001'; END IF;
 INSERT INTO public.branches(organization_id,name,code,address,city,governorate,phone,eta_branch_code,is_main,created_by)
 VALUES(v_org,btrim(p_name),v_code,p_address,p_city,p_governorate,p_phone,p_eta_branch_code,false,v_emp) RETURNING id INTO v_id;
 INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind,created_by) VALUES(v_org,v_id,'خزنة '||btrim(p_name),'safe',v_emp);
 IF (SELECT role FROM public.employees WHERE id=v_emp)<>'OWNER' THEN INSERT INTO public.employee_branches(organization_id,employee_id,branch_id) VALUES(v_org,v_emp,v_id); END IF;
 PERFORM app.write_audit('branch.created','branch',v_id,p_after=>(SELECT to_jsonb(b) FROM public.branches b WHERE id=v_id));
 RETURN v_id;
EXCEPTION WHEN unique_violation THEN
 GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
 IF v_constraint='branches_code_key' THEN RAISE EXCEPTION 'BRANCH_CODE_TAKEN' USING ERRCODE='P0001'; END IF;
 RAISE;
END $$;

CREATE FUNCTION public.update_branch(p_branch_id uuid,p_name text,p_address text,p_city text,p_governorate text,p_phone text,p_eta_branch_code text,p_default_cash_account_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid; v_org uuid; v_before public.branches%ROWTYPE;
BEGIN
 v_emp:=app.require_permission('branch.manage'); v_org:=app.current_org_id();
 SELECT * INTO v_before FROM public.branches WHERE id=p_branch_id AND organization_id=v_org FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 PERFORM app.require_branch_access(p_branch_id);
 IF NULLIF(btrim(p_name),'') IS NULL OR length(btrim(p_name))>100 THEN RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE='P0001'; END IF;
 IF length(p_eta_branch_code)>20 THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 UPDATE public.branches SET name=btrim(p_name),address=p_address,city=p_city,governorate=p_governorate,phone=p_phone,eta_branch_code=p_eta_branch_code,default_cash_account_id=p_default_cash_account_id,updated_by=v_emp,updated_at=now() WHERE id=p_branch_id;
 PERFORM app.write_audit('branch.updated','branch',p_branch_id,p_before=>to_jsonb(v_before),p_after=>(SELECT to_jsonb(b) FROM public.branches b WHERE id=p_branch_id));
END $$;

CREATE FUNCTION app.branch_deactivation_counts(p_branch_id uuid,p_org uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('open_shifts',(SELECT count(*) FROM public.shifts WHERE organization_id=p_org AND branch_id=p_branch_id AND status='open'),
 'stock_units',(SELECT COALESCE(sum(on_hand),0) FROM public.stock_levels WHERE organization_id=p_org AND branch_id=p_branch_id),
 'cash_balance',(SELECT COALESCE(sum(b.balance),0)::numeric(18,2)::text FROM public.cash_balances b JOIN public.cash_accounts a ON a.id=b.cash_account_id AND a.organization_id=b.organization_id WHERE a.organization_id=p_org AND a.branch_id=p_branch_id))
$$;
REVOKE ALL ON FUNCTION app.branch_deactivation_counts(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.branch_deactivation_check(p_branch_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid; v_org uuid;
BEGIN
 v_emp:=app.require_permission('branch.manage'); v_org:=app.current_org_id();
 IF NOT EXISTS(SELECT 1 FROM public.branches WHERE id=p_branch_id AND organization_id=v_org) THEN RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 IF NOT app.has_branch_access(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_DENIED: %',p_branch_id USING ERRCODE='42501'; END IF;
 RETURN app.branch_deactivation_counts(p_branch_id,v_org);
END $$;
CREATE FUNCTION public.set_branch_active(p_branch_id uuid,p_active boolean,p_reason text,p_confirm boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_emp uuid; v_org uuid; v_before public.branches%ROWTYPE; v_counts jsonb;
BEGIN
 v_emp:=app.require_permission('branch.manage'); v_org:=app.current_org_id();
 PERFORM 1 FROM public.organizations WHERE id=v_org FOR UPDATE;
 SELECT * INTO v_before FROM public.branches WHERE id=p_branch_id AND organization_id=v_org FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE='P0001'; END IF;
 -- Reactivation and no-op requests still require branch scope, but must accept an inactive target.
 IF NOT app.has_branch_access(p_branch_id) THEN RAISE EXCEPTION 'BRANCH_DENIED: %',p_branch_id USING ERRCODE='42501'; END IF;
 IF p_active IS NULL THEN RAISE EXCEPTION 'VALIDATION_FAILED' USING ERRCODE='P0001'; END IF;
 IF v_before.is_active=p_active THEN RETURN; END IF;
 IF NOT p_active THEN
  PERFORM app.require_branch_access(p_branch_id);
  IF v_before.is_main THEN RAISE EXCEPTION 'MAIN_BRANCH_REQUIRED' USING ERRCODE='P0001'; END IF;
  IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='P0001'; END IF;
  v_counts:=app.branch_deactivation_counts(p_branch_id,v_org);
  IF NOT COALESCE(p_confirm,false) AND ((v_counts->>'open_shifts')::bigint<>0 OR (v_counts->>'stock_units')::bigint<>0 OR (v_counts->>'cash_balance')::numeric<>0) THEN RAISE EXCEPTION 'BRANCH_DEACTIVATE_NEEDS_CONFIRM' USING ERRCODE='P0001',DETAIL=v_counts::text; END IF;
 END IF;
 UPDATE public.branches SET is_active=p_active,updated_by=v_emp,updated_at=now() WHERE id=p_branch_id;
 PERFORM app.write_audit(CASE WHEN p_active THEN 'branch.reactivated' ELSE 'branch.deactivated' END,'branch',p_branch_id,p_severity=>CASE WHEN p_active THEN 'info'::public.audit_severity ELSE 'warning'::public.audit_severity END,p_before=>jsonb_build_object('is_active',v_before.is_active),p_after=>jsonb_build_object('is_active',p_active)||COALESCE(v_counts,'{}'),p_reason=>p_reason);
END $$;
REVOKE ALL ON FUNCTION public.create_branch(text,text,text,text,text,text,text),public.update_branch(uuid,text,text,text,text,text,text,uuid),public.set_branch_active(uuid,boolean,text,boolean),public.branch_deactivation_check(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_branch(text,text,text,text,text,text,text),public.update_branch(uuid,text,text,text,text,text,text,uuid),public.set_branch_active(uuid,boolean,text,boolean),public.branch_deactivation_check(uuid) TO authenticated;
