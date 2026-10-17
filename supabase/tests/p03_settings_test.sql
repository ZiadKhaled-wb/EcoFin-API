\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; PERFORM t.expect(n,false,'no error'); EXCEPTION WHEN others THEN PERFORM t.expect(n,split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
-- The app.* helpers have no grants; sales functions (definers) call them. These wrappers do the same.
CREATE FUNCTION t.check_discount(p numeric) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT app.check_discount(p) $$;
CREATE FUNCTION t.policy_version(o uuid) RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT (app.current_installment_policy(o)).version $$;
-- An imported contract (is_migrated: no sale or order needed) with real customer, branch and policy.
CREATE FUNCTION t.ok_contract(o uuid) RETURNS public.creditor_model LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_customer uuid; v_creditor public.creditor_model;
BEGIN
    INSERT INTO public.customers(organization_id,full_name) VALUES(o,'P04 customer') RETURNING id INTO v_customer;
    INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,policy_id,creditor,cash_price,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,idempotency_key,is_migrated)
    VALUES(o,'P04-OK-1',v_customer,(SELECT id FROM public.branches WHERE organization_id=o AND is_main),(SELECT id FROM public.installment_policies WHERE organization_id=o ORDER BY version DESC LIMIT 1),'in_house',100,100,0,0,100,1,'monthly',current_date,'p04-allowed-0001',true)
    RETURNING creditor INTO v_creditor;
    RETURN v_creditor;
END $$;
CREATE FUNCTION t.try_contract(o uuid) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
    INSERT INTO public.contracts(organization_id,number,customer_id,branch_id,policy_id,creditor,cash_price,financed_amount,markup_pct,markup_amount,total_payable,installments_count,frequency,first_due_date,idempotency_key)
    VALUES(o,'BLOCKED','a0300000-0000-4000-8000-000000000099','a0300000-0000-4000-8000-000000000099','a0300000-0000-4000-8000-000000000099','in_house',100,100,0,0,100,1,'monthly',current_date,'disabled-0001')
$$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- Shops a and b (retail: installments module), starter (no installments module).
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('P03 '||s,'p03-'||s,p,'Owner',s||'@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a','retail',repeat('d',64)),('b','retail',repeat('e',64)),('starter','starter',repeat('f',64)))v(s,p,h);
INSERT INTO auth.users(id,email) VALUES('a0300000-0000-4000-8000-000000000001','a@example.com'),('a0300000-0000-4000-8000-000000000002','b@example.com'),('a0300000-0000-4000-8000-000000000003','starter@example.com'),('a0300000-0000-4000-8000-000000000004','cashier@example.com'),('a0300000-0000-4000-8000-000000000005','cashier2@example.com');
SELECT public.accept_invite(repeat('d',64),'a0300000-0000-4000-8000-000000000001');
SELECT public.accept_invite(repeat('e',64),'a0300000-0000-4000-8000-000000000002');
SELECT public.accept_invite(repeat('f',64),'a0300000-0000-4000-8000-000000000003');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0300000-0000-4000-8000-000000000004','Cashier','CASHIER'),(t.org('a'),'a0300000-0000-4000-8000-000000000005','Cashier two','CASHIER');
INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_key,granted) SELECT t.org('a'),id,'discount.above_cap',true FROM public.employees WHERE auth_user_id='a0300000-0000-4000-8000-000000000005';
INSERT INTO public.tax_classes(organization_id,name,rate) VALUES(t.org('a'),'VAT 14',14) RETURNING id \gset tax_a_
INSERT INTO public.tax_classes(organization_id,name,rate) VALUES(t.org('b'),'VAT 14',14) RETURNING id \gset tax_b_
INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('b'),t.org('b')||'/logo.png','image/png',1,'logo') RETURNING id \gset logo_b_
INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('a'),t.org('a')||'/logo.png','image/png',1,'logo') RETURNING id \gset logo_a_
INSERT INTO public.files(organization_id,path,mime,size_bytes,purpose) VALUES(t.org('a'),t.org('a')||'/doc.pdf','application/pdf',1,'other') RETURNING id \gset other_a_

SELECT t.expect('provisioned defaults',(SELECT receipt_fields->>'customer'='true' AND (credit_score_weights->>'guarantors')::int=40 AND (legal_referral_days->>'daily')::int=35 AND currency='EGP' AND global_min_stock=3 FROM public.org_settings WHERE organization_id=t.org('a')) AND (SELECT version=1 AND amount_tiers='[]' AND down_payment_rules='{}' AND min_sale_amount=0 FROM public.installment_policies WHERE organization_id=t.org('a')));

-- Owner of shop a reads and changes settings.
SELECT t.as_user('a0300000-0000-4000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('owner reads settings',(SELECT s->>'name'='P03 a' AND (s#>>'{installment_policy,version}')::int=1 AND (s#>>'{my_discount,cap_pct}')::numeric=100 AND jsonb_array_length(s->'tax_class_options')=4 AND s->>'purchase_approval_threshold' IS NULL FROM public.get_shop_settings() s));
SELECT public.update_org_settings(jsonb_build_object('name',' Shop A2 ','address','Cairo','phone','0100','receipt_fields',jsonb_build_object('customer',false),'discount_caps',jsonb_build_object('CASHIER',5,'BRANCH_MANAGER',15),'credit_score_weights',jsonb_build_object('guarantors',50,'income',30,'residence',10,'identity',10),'default_tax_class_id',:'tax_a_id','logo_file_id',:'logo_a_id','purchase_approval_threshold','25000.50','legal_referral_days',jsonb_build_object('weekly',49)));
SELECT t.expect('profile starts with in-house financing', (public.get_shop_profile()->>'creditor_model')='in_house' AND public.get_shop_profile()->>'installments_enabled'='true');
SELECT public.update_org_profile('{"legal_name":"Shop A Legal","commercial_register":"CR-100","tax_registration_no":"TAX-100","consumer_finance_legal_status":"Owner supplied","installments_enabled":false}');
SELECT t.expect('profile updates legal fields and switch', (public.get_shop_profile()->>'legal_name')='Shop A Legal' AND public.get_shop_profile()->>'commercial_register'='CR-100' AND public.get_shop_profile()->>'tax_registration_no'='TAX-100' AND public.get_shop_profile()->>'consumer_finance_legal_status'='Owner supplied' AND public.get_shop_profile()->>'installments_enabled'='false');
SELECT t.error('settings endpoint cannot edit tax registration',$q$SELECT public.update_org_settings('{"tax_registration_no":"BYPASS"}')$q$,'SETTINGS_INVALID');
SELECT t.error('disabled installments reject contract insert',format('SELECT t.try_contract(%L)',t.org('a')),'INSTALLMENTS_DISABLED');
SELECT public.update_org_profile('{"installments_enabled":true}');
SELECT t.expect('enabled installments accept a contract that stores the shop creditor', t.ok_contract(t.org('a'))=(SELECT creditor_model FROM public.organizations WHERE id=t.org('a')));
SELECT t.expect('settings read back',(SELECT s->>'name'='Shop A2' AND s->>'address'='Cairo' AND s->>'purchase_approval_threshold'='25000.50' AND s#>>'{receipt_fields,customer}'='false' AND s#>>'{receipt_fields,logo}'='true' AND (s#>>'{legal_referral_days,weekly}')::int=49 AND (s#>>'{legal_referral_days,daily}')::int=35 AND s->>'default_tax_class_id'=:'tax_a_id' FROM public.get_shop_settings() s));
SELECT public.update_org_settings(jsonb_build_object('name','Shop A2','address','Cairo'));
SELECT t.error('unknown key',$q$SELECT public.update_org_settings('{"organization_id":"x"}')$q$,'SETTINGS_INVALID');
SELECT t.error('name required',$q$SELECT public.update_org_settings('{"name":"  "}')$q$,'NAME_REQUIRED');
SELECT t.error('bad timezone',$q$SELECT public.update_org_settings('{"timezone":"Mars/Base"}')$q$,'SETTINGS_INVALID');
SELECT t.error('owner has no cap entry',$q$SELECT public.update_org_settings('{"discount_caps":{"OWNER":50}}')$q$,'SETTINGS_INVALID');
SELECT t.error('cap above 100',$q$SELECT public.update_org_settings('{"discount_caps":{"CASHIER":101}}')$q$,'SETTINGS_INVALID');
SELECT t.error('unknown role cap',$q$SELECT public.update_org_settings('{"discount_caps":{"BOSS":5}}')$q$,'SETTINGS_INVALID');
SELECT t.error('weights must sum to 100',$q$SELECT public.update_org_settings('{"credit_score_weights":{"guarantors":40,"income":30,"residence":10,"identity":10}}')$q$,'SETTINGS_INVALID');
SELECT t.error('unknown receipt field',$q$SELECT public.update_org_settings('{"receipt_fields":{"qr":true}}')$q$,'SETTINGS_INVALID');
SELECT t.error('paper width 58 or 80',$q$SELECT public.update_org_settings('{"receipt_width_mm":70}')$q$,'SETTINGS_INVALID');
SELECT t.error('bad theme colour',$q$SELECT public.update_org_settings('{"theme_color":"blue"}')$q$,'SETTINGS_INVALID');
SELECT t.error('bad language',$q$SELECT public.update_org_settings('{"default_language":"fr"}')$q$,'SETTINGS_INVALID');
SELECT t.error('bad legal frequency',$q$SELECT public.update_org_settings('{"legal_referral_days":{"yearly":3}}')$q$,'SETTINGS_INVALID');
SELECT t.error('foreign tax class',format('SELECT public.update_org_settings(%L)',jsonb_build_object('default_tax_class_id',:'tax_b_id')),'TAX_CLASS_NOT_FOUND');
SELECT t.error('foreign logo file',format('SELECT public.update_org_settings(%L)',jsonb_build_object('logo_file_id',:'logo_b_id')),'FILE_NOT_FOUND');
SELECT t.error('logo must be a logo file',format('SELECT public.update_org_settings(%L)',jsonb_build_object('logo_file_id',:'other_a_id')),'FILE_NOT_FOUND');
RESET ROLE;
SELECT t.expect('both profile updates are audited', (SELECT count(*)=2 AND bool_and(action='org.profile_updated') FROM public.audit_log WHERE organization_id=t.org('a') AND action='org.profile_updated'));
SELECT t.expect('one audit row with changed keys only',(SELECT count(*)=1 FROM public.audit_log WHERE organization_id=t.org('a') AND action='org.settings_updated') AND (SELECT before->>'name'='P03 a' AND after->>'name'='Shop A2' AND NOT (after ? 'timezone') AND after ? 'discount_caps' FROM public.audit_log WHERE organization_id=t.org('a') AND action='org.settings_updated'));
SELECT t.expect('foreign shop unchanged',(SELECT o.name='P03 b' AND o.address IS NULL AND s.discount_caps='{}' FROM public.organizations o JOIN public.org_settings s ON s.organization_id=o.id WHERE o.id=t.org('b')));

-- Done when (discount cap): changing the cap changes what a cashier may give.
SELECT t.as_user('a0300000-0000-4000-8000-000000000004',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.check_discount(5);
SELECT t.expect('cashier within cap',true);
SELECT t.error('cashier above cap',$q$SELECT t.check_discount(6)$q$,'DISCOUNT_ABOVE_CAP');
SELECT t.error('cashier cannot change settings',$q$SELECT public.update_org_settings('{"discount_caps":{"CASHIER":50}}')$q$,'PERMISSION_DENIED');
SELECT t.error('cashier cannot list policies',$q$SELECT public.list_installment_policies()$q$,'PERMISSION_DENIED');
SELECT t.error('cashier cannot publish policy',$q$SELECT public.publish_installment_policy('{"grace_days":3}')$q$,'PERMISSION_DENIED');
SELECT t.expect('cashier reads own cap',(SELECT (s#>>'{my_discount,cap_pct}')::numeric=5 AND s#>>'{my_discount,above_cap_allowed}'='false' FROM public.get_shop_settings() s));
SELECT t.as_user('a0300000-0000-4000-8000-000000000001',t.org('a'));
SELECT public.update_org_settings('{"discount_caps":{"CASHIER":10}}');
SELECT t.as_user('a0300000-0000-4000-8000-000000000004',t.org('a'));
SELECT t.check_discount(6);
SELECT t.expect('raised cap allows 6%',true);
SELECT t.error('raised cap still blocks 11%',$q$SELECT t.check_discount(11)$q$,'DISCOUNT_ABOVE_CAP');
SELECT t.as_user('a0300000-0000-4000-8000-000000000005',t.org('a'));
SELECT t.check_discount(50);
SELECT t.expect('discount.above_cap override passes',true);
SELECT t.as_user('a0300000-0000-4000-8000-000000000001',t.org('b'));
SELECT t.error('owner a aimed at shop b',$q$SELECT public.update_org_settings('{"name":"Hijack"}')$q$,'NOT_AN_EMPLOYEE');

-- Done when (installment policy): a new version changes the policy new contracts read; old versions stay.
SELECT t.as_user('a0300000-0000-4000-8000-000000000001',t.org('a'));
INSERT INTO t.ids SELECT 'v1',id FROM public.installment_policies WHERE organization_id=t.org('a') AND version=1;
INSERT INTO t.ids VALUES('v2',public.publish_installment_policy('{"min_down_payment_pct":"10","max_down_payment_pct":"50","max_months":15,"allowed_frequencies":["monthly","daily"],"down_payment_rules":{"monthly":"one_installment","daily":"installment_per_day_of_month"},"min_installment_by_frequency":{"daily":"50.00","monthly":"500.00"},"amount_tiers":[{"up_to_amount":"100000.00","max_months":10},{"up_to_amount":"1000000.00","max_months":15}],"markup_tiers":[{"up_to_months":6,"pct":10},{"up_to_months":15,"pct":25}],"min_sale_amount":"2500.00","grace_days":3}'));
SELECT t.expect('new version is current',t.policy_version(t.org('a'))=2 AND (SELECT max_months=15 AND allowed_frequencies='{monthly,daily}' AND max_down_payment_pct=50 AND min_sale_amount=2500 AND created_by IS NOT NULL FROM public.installment_policies WHERE id=t.id('v2')));
SELECT t.expect('old version unchanged',(SELECT version=1 AND max_months=12 AND min_down_payment_pct=0 AND amount_tiers='[]' FROM public.installment_policies WHERE id=t.id('v1')));
SELECT t.expect('same terms publish no new version',public.publish_installment_policy('{"grace_days":3}')=t.id('v2') AND t.policy_version(t.org('a'))=2);
INSERT INTO t.ids VALUES('v3',public.publish_installment_policy('{"grace_days":5}'));
SELECT t.expect('partial publish keeps the rest',(SELECT version=3 AND grace_days=5 AND max_months=15 AND down_payment_rules->>'daily'='installment_per_day_of_month' FROM public.installment_policies WHERE id=t.id('v3')));
SELECT t.expect('settings show current policy',(SELECT (s#>>'{installment_policy,version}')::int=3 AND s#>>'{installment_policy,min_sale_amount}'='2500.00' AND s#>>'{installment_policy,min_down_payment_pct}'='10.00' FROM public.get_shop_settings() s));
SELECT t.expect('history newest first',(SELECT jsonb_array_length(h)=3 AND (h->0->>'version')::int=3 FROM public.list_installment_policies() h));
SELECT t.expect('publish audited',(SELECT count(*)=2 FROM public.audit_log WHERE organization_id=t.org('a') AND action='installment_policy.published') AND EXISTS(SELECT 1 FROM public.audit_log WHERE action='installment_policy.published' AND entity_id=t.id('v2') AND (before->>'version')::int=1));
SELECT t.error('markup must cover max months',$q$SELECT public.publish_installment_policy('{"max_months":24}')$q$,'POLICY_INVALID');
SELECT t.error('day-of-month rule is daily only',$q$SELECT public.publish_installment_policy('{"down_payment_rules":{"monthly":"installment_per_day_of_month"}}')$q$,'POLICY_INVALID');
SELECT t.error('min installment for a frequency not allowed',$q$SELECT public.publish_installment_policy('{"min_installment_by_frequency":{"weekly":"100.00"}}')$q$,'POLICY_INVALID');
SELECT t.error('amount tiers must rise',$q$SELECT public.publish_installment_policy('{"amount_tiers":[{"up_to_amount":"5000.00","max_months":6},{"up_to_amount":"4000.00","max_months":8}]}')$q$,'POLICY_INVALID');
SELECT t.error('amount tier above max months',$q$SELECT public.publish_installment_policy('{"amount_tiers":[{"up_to_amount":"5000.00","max_months":16}]}')$q$,'POLICY_INVALID');
SELECT t.error('max down below min down',$q$SELECT public.publish_installment_policy('{"max_down_payment_pct":"5"}')$q$,'POLICY_INVALID');
SELECT t.error('unknown frequency',$q$SELECT public.publish_installment_policy('{"allowed_frequencies":["yearly"]}')$q$,'POLICY_INVALID');
SELECT t.error('unknown policy key',$q$SELECT public.publish_installment_policy('{"version":9}')$q$,'POLICY_INVALID');
SELECT t.error('a late fee is refused (N04, rule 4)',$q$SELECT public.publish_installment_policy('{"late_fee_type":"percent","late_fee_value":"150"}')$q$,'LATE_FEES_NOT_ALLOWED');
RESET ROLE;
SELECT t.expect('failed publishes leave no version',(SELECT count(*)=3 FROM public.installment_policies WHERE organization_id=t.org('a')) AND (SELECT count(*)=1 FROM public.installment_policies WHERE organization_id=t.org('b')));
SELECT t.as_user('a0300000-0000-4000-8000-000000000003',t.org('starter'));
SET LOCAL ROLE authenticated;
SELECT t.error('starter plan has no installments',$q$SELECT public.publish_installment_policy('{"grace_days":3}')$q$,'MODULE_NOT_IN_PLAN');
SELECT public.update_org_settings('{"theme_color":"#112233"}');
SELECT t.expect('starter can still edit settings',(SELECT s->>'theme_color'='#112233' FROM public.get_shop_settings() s));
RESET ROLE;
SELECT t.expect('new RPCs no anon grants',NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN('get_shop_settings','update_org_settings','publish_installment_policy','list_installment_policies') AND has_function_privilege('anon',oid,'EXECUTE')));
SELECT t.expect('app helpers not granted',NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='app'::regnamespace AND proname IN('current_installment_policy','discount_cap_pct','check_discount','installment_policy_json') AND has_function_privilege('authenticated',oid,'EXECUTE')));
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
