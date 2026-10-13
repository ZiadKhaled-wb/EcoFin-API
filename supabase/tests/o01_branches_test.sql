\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
-- O03: a shift needs the paired POS device of the request. t.open_shift puts a free device of the
-- branch in the request headers (x-device-id, as the API does once it has resolved a device
-- token) and then calls public.open_shift unchanged.
CREATE FUNCTION t.pos(p_branch uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_org uuid := app.current_org_id(); v_id uuid;
BEGIN
  IF v_org IS NULL OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch AND b.organization_id = v_org) THEN
    RETURN NULL;
  END IF;
  SELECT d.id INTO v_id FROM public.devices d
  WHERE d.organization_id = v_org AND d.branch_id = p_branch AND d.is_active AND d.archived_at IS NULL AND d.name LIKE 'Test POS %'
    AND NOT EXISTS (SELECT 1 FROM public.shifts s WHERE s.device_id = d.id AND s.status = 'open')
  ORDER BY d.name LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO public.devices (organization_id, branch_id, name) VALUES (v_org, p_branch, 'Test POS ' || gen_random_uuid())
    RETURNING id INTO v_id;
  END IF;
  PERFORM set_config('request.headers',
    (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb || jsonb_build_object('x-device-id', v_id))::text, false);
  RETURN v_id;
END $$;
CREATE FUNCTION t.open_shift(p_branch uuid, p_float text, p_key text, p_vault uuid DEFAULT NULL, p_device uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  -- A named device is the one "paired" for this call; otherwise any free device of the branch.
  IF p_device IS NOT NULL THEN
    PERFORM set_config('request.headers',
      (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::jsonb || jsonb_build_object('x-device-id', p_device))::text, false);
  ELSE
    PERFORM t.pos(p_branch);
  END IF;
  RETURN public.open_shift(p_branch, p_float, p_key, p_vault, p_device);
END $$;
GRANT EXECUTE ON FUNCTION t.pos(uuid), t.open_shift(uuid, text, text, uuid, uuid) TO authenticated;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text,expected jsonb DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d text; BEGIN BEGIN EXECUTE q; PERFORM t.expect(n,false,'no error'); EXCEPTION WHEN others THEN GET STACKED DIAGNOSTICS d=PG_EXCEPTION_DETAIL; PERFORM t.expect(n,split_part(SQLERRM,':',1)=c AND (expected IS NULL OR d::jsonb=expected),SQLERRM||' '||d); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.main(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'branch_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.emp(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'owner_employee_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.access(b uuid) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT app.require_branch_access(b) $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('O01 '||s,'o01-'||s,p,'Owner',s||'@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a','retail',repeat('a',64)),('b','enterprise',repeat('b',64)),('starter','starter',repeat('c',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0100000-0000-4000-8000-000000000001','a@example.com'),('a0100000-0000-4000-8000-000000000002','b@example.com'),('a0100000-0000-4000-8000-000000000003','starter@example.com'),('a0100000-0000-4000-8000-000000000004','cashier@example.com'),('a0100000-0000-4000-8000-000000000005','manager@example.com');
SELECT public.accept_invite(repeat('a',64),'a0100000-0000-4000-8000-000000000001');
SELECT public.accept_invite(repeat('b',64),'a0100000-0000-4000-8000-000000000002');
SELECT public.accept_invite(repeat('c',64),'a0100000-0000-4000-8000-000000000003');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0100000-0000-4000-8000-000000000004','Cashier','CASHIER'),(t.org('b'),'a0100000-0000-4000-8000-000000000005','Manager','BRANCH_MANAGER');
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) SELECT t.org('b'),id,'branch.manage',true FROM public.employees WHERE auth_user_id='a0100000-0000-4000-8000-000000000005';
SELECT t.expect('provisioned main default safe',(SELECT count(*)=3 FROM public.branches b JOIN public.cash_accounts c ON c.id=b.default_cash_account_id WHERE b.organization_id IN (SELECT t.org(tag) FROM t.shops) AND b.is_main AND c.kind='safe' AND c.is_active AND c.branch_id=b.id));
SELECT t.as_user('a0100000-0000-4000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('second',public.create_branch('Second','b2',NULL,NULL,NULL,'123','ETA2'));
SELECT t.error('duplicate code',$q$SELECT public.create_branch('Duplicate','B2',NULL,NULL,NULL,NULL,NULL)$q$,'BRANCH_CODE_TAKEN');
SELECT t.error('invalid code',$q$SELECT public.create_branch('Invalid','TOOLONG7',NULL,NULL,NULL,NULL,NULL)$q$,'BRANCH_CODE_INVALID');
SELECT t.error('name required',$q$SELECT public.create_branch(' ','B3',NULL,NULL,NULL,NULL,NULL)$q$,'NAME_REQUIRED');
SELECT t.error('cross shop update',$q$SELECT public.update_branch(t.main('b'),'Hijack',NULL,NULL,NULL,NULL,NULL,NULL)$q$,'BRANCH_NOT_FOUND');
SELECT t.error('cross shop active',$q$SELECT public.set_branch_active(t.main('b'),false,'x',true)$q$,'BRANCH_NOT_FOUND');
SELECT t.error('cross shop check',$q$SELECT public.branch_deactivation_check(t.main('b'))$q$,'BRANCH_NOT_FOUND');
SELECT t.error('wrong branch safe',$q$SELECT public.update_branch(t.id('second'),'Second',NULL,NULL,NULL,NULL,NULL,(SELECT default_cash_account_id FROM public.branches WHERE id=t.main('a')))$q$,'VAULT_INVALID');
SELECT t.error('main cannot deactivate',$q$SELECT public.set_branch_active(t.main('a'),false,'x',false)$q$,'MAIN_BRANCH_REQUIRED');
SELECT t.error('reason required',$q$SELECT public.set_branch_active(t.id('second'),false,' ',false)$q$,'REASON_REQUIRED');
RESET ROLE;
SELECT t.expect('created normalized branch safe and audit',(SELECT code='B2' AND created_by=t.emp('a') AND default_cash_account_id IS NOT NULL FROM public.branches WHERE id=t.id('second')) AND EXISTS(SELECT 1 FROM public.cash_accounts WHERE id=(SELECT default_cash_account_id FROM public.branches WHERE id=t.id('second')) AND name='خزنة Second' AND kind='safe') AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='branch.created' AND entity_id=t.id('second')));
SELECT t.expect('foreign branch unchanged',(SELECT name='Main' AND is_active FROM public.branches WHERE id=t.main('b')));
INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind) VALUES(t.org('a'),t.id('second'),'Drawer','drawer') RETURNING id \gset drawer_
SELECT t.error('drawer invalid',format('SELECT public.update_branch(%L,''Second'',NULL,NULL,NULL,NULL,NULL,%L)',t.id('second'),:'drawer_id'),'VAULT_INVALID');
INSERT INTO public.cash_accounts(organization_id,branch_id,name,kind) VALUES(t.org('a'),t.id('second'),'Other safe','safe') RETURNING id \gset safe_
SELECT public.update_branch(t.id('second'),'Edited','Address','City','Gov','456','E2',:'safe_id');
SELECT t.expect('second safe and update audit',(SELECT name='Edited' AND code='B2' AND default_cash_account_id=:'safe_id'::uuid AND updated_by=t.emp('a') FROM public.branches WHERE id=t.id('second')) AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='branch.updated' AND entity_id=t.id('second') AND before->>'name'='Second' AND after->>'name'='Edited'));
INSERT INTO public.shifts(organization_id,number,branch_id,employee_id,drawer_account_id,idempotency_key) VALUES(t.org('a'),'B2-SH-26-1',t.id('second'),t.emp('a'),:'drawer_id','o01-shift');
SELECT t.error('open shift warning',$q$SELECT public.set_branch_active(t.id('second'),false,'close',false)$q$,'BRANCH_DEACTIVATE_NEEDS_CONFIRM','{"open_shifts":1,"stock_units":0,"cash_balance":"0.00"}');
SELECT t.expect('check counts',public.branch_deactivation_check(t.id('second'))='{"open_shifts":1,"stock_units":0,"cash_balance":"0.00"}'::jsonb);
SELECT public.set_branch_active(t.id('second'),false,'close',true);
SELECT t.expect('warning audit reason',(SELECT count(*)=1 FROM public.audit_log WHERE entity_id=t.id('second') AND action='branch.deactivated' AND severity='warning' AND reason='close'));
SELECT t.error('inactive branch access',$q$SELECT t.access(t.id('second'))$q$,'BRANCH_INACTIVE');
SELECT public.set_branch_active(t.id('second'),false,'close',true);
SELECT t.expect('already inactive no second audit',(SELECT count(*)=1 FROM public.audit_log WHERE action='branch.deactivated' AND entity_id=t.id('second')));
SELECT public.set_branch_active(t.id('second'),true,NULL,false);
UPDATE public.shifts SET status='closed',closed_at=now(),counted_cash=0 WHERE organization_id=t.org('a');
INSERT INTO public.tax_classes(organization_id,name,rate) VALUES(t.org('a'),'Tax',0) RETURNING id \gset tax_
INSERT INTO public.products(organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized) VALUES(t.org('a'),'Product','O01-P',100,:'tax_id',false) RETURNING id \gset product_
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(t.org('a'),:'product_id',t.id('second'),5,'purchase_in','purchase_invoice',gen_random_uuid());
SELECT t.error('stock warning',$q$SELECT public.set_branch_active(t.id('second'),false,'close',false)$q$,'BRANCH_DEACTIVATE_NEEDS_CONFIRM','{"open_shifts":0,"stock_units":5,"cash_balance":"0.00"}');
SELECT public.set_branch_active(t.id('second'),false,'stock warning accepted',true);
SELECT public.set_branch_active(t.id('second'),true,NULL,false);
INSERT INTO public.stock_movements(organization_id,product_id,branch_id,quantity,type,source_type,source_id) VALUES(t.org('a'),:'product_id',t.id('second'),-5,'sale_out','sale',gen_random_uuid());
INSERT INTO public.cash_movements(organization_id,cash_account_id,amount,type,source_type,source_id) VALUES(t.org('a'),:'safe_id',30.25,'float_in','shift',gen_random_uuid());
SELECT t.error('cash warning',$q$SELECT public.set_branch_active(t.id('second'),false,'close',false)$q$,'BRANCH_DEACTIVATE_NEEDS_CONFIRM','{"open_shifts":0,"stock_units":0,"cash_balance":"30.25"}');
SELECT public.set_branch_active(t.id('second'),false,'cash warning accepted',true);
SELECT public.set_branch_active(t.id('second'),true,NULL,false);
INSERT INTO public.cash_movements(organization_id,cash_account_id,amount,type,source_type,source_id) VALUES(t.org('a'),:'safe_id',-30.25,'expense','expense',gen_random_uuid());
SELECT public.set_branch_active(t.id('second'),false,'clean',false);
SELECT t.expect('clean deactivation',(SELECT NOT is_active FROM public.branches WHERE id=t.id('second')));
SELECT t.as_user('a0100000-0000-4000-8000-000000000004',t.org('a'));
SELECT t.error('cashier denied',$q$SELECT public.create_branch('Third','B3',NULL,NULL,NULL,NULL,NULL)$q$,'PERMISSION_DENIED');
SELECT t.as_user('a0100000-0000-4000-8000-000000000003',t.org('starter'));
SELECT t.error('starter limit atomic',$q$SELECT public.create_branch('Extra','B2',NULL,NULL,NULL,NULL,NULL)$q$,'PLAN_LIMIT_REACHED');
SELECT t.expect('no partial starter branch safe',(SELECT count(*)=1 FROM public.branches WHERE organization_id=t.org('starter')) AND (SELECT count(*)=1 FROM public.cash_accounts WHERE organization_id=t.org('starter')));
INSERT INTO public.branches(organization_id,code,name,is_active) VALUES(t.org('starter'),'B2','Inactive',false) RETURNING id \gset inactive_
SELECT t.error('reactivation limit',format('SELECT public.set_branch_active(%L,true,NULL,false)',:'inactive_id'),'PLAN_LIMIT_REACHED');
SELECT t.as_user('a0100000-0000-4000-8000-000000000005',t.org('b'));
INSERT INTO t.ids VALUES('manager',public.create_branch('Manager made','B2',NULL,NULL,NULL,NULL,NULL));
SELECT t.expect('manager creator access',app.has_branch_access(t.id('manager')) AND EXISTS(SELECT 1 FROM public.employee_branches WHERE branch_id=t.id('manager')));
SELECT t.expect('new RPCs no anon grants',NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN('create_branch','update_branch','set_branch_active','branch_deactivation_check') AND has_function_privilege('anon',oid,'EXECUTE')));
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
