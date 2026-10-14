// TEST4 local-only, isolated language fixtures; no seeded INT-4 users or devices are changed.
import { createClient } from '@supabase/supabase-js';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
const language = process.argv[2];
if (!['ar', 'en'].includes(language)) throw new Error('language must be ar or en');
const url = process.env.SUPABASE_URL ?? '';
if (!/^http:\/\/(127\.0\.0\.1|localhost):54321\/?$/.test(url))
  throw new Error('TEST4 fixtures require local Supabase');
const db = createClient(url, process.env.SUPABASE_SERVICE_ROLE_KEY ?? '', {
  auth: { persistSession: false, autoRefreshToken: false },
});
const stamp = randomBytes(8).toString('hex');
const email = `test4.${language}.${stamp}@ecotech.test`;
const password = 'LocalDev-Only-2026!';
const user = await db.auth.admin.createUser({ email, password, email_confirm: true });
if (user.error) throw user.error;
const invite = randomBytes(32).toString('hex');
const serial = `TEST4-${language.toUpperCase()}-${stamp}`.toUpperCase();
const sql = `BEGIN;
SELECT set_config('request.jwt.claim.sub','f0000000-0000-0000-0000-000000000001',true);
CREATE TEMP TABLE fixture AS SELECT public.admin_provision_organization('TEST4 ${language}','test4-${language}-${stamp}','retail_pro','Owner','${email}',NULL,'Main','${invite}',now()+interval '1 day') result;
SELECT public.accept_invite('${invite}','${user.data.user.id}');
SELECT set_config('request.jwt.claim.sub','${user.data.user.id}',true);
SELECT set_config('request.headers',json_build_object('x-org-id',(SELECT result->>'organization_id' FROM fixture))::text,true);
UPDATE public.organizations SET legal_name='TEST4 Shop',tax_registration_no='674859545',default_language='${language}' WHERE id=(SELECT (result->>'organization_id')::uuid FROM fixture);
UPDATE public.org_settings SET prices_include_vat=true,discount_caps='{"CASHIER":5,"BRANCH_MANAGER":15}' WHERE organization_id=(SELECT (result->>'organization_id')::uuid FROM fixture);
UPDATE public.branches SET eta_branch_code='0',address='Main Street',city='Nasr City',governorate='Cairo',building_number='1' WHERE organization_id=(SELECT (result->>'organization_id')::uuid FROM fixture);
CREATE TEMP TABLE products AS SELECT public.create_product('{"name_ar":"كرسي","name_en":"Chair","sku":"TEST4-CHAIR","barcode":"6222000000011","cash_price":"1000.00","eta_item_code":"EG-674859545-T4CH","eta_item_type":"EGS"}') chair,
public.create_product('{"name_ar":"هاتف","name_en":"Phone","sku":"TEST4-PHONE","cash_price":"5000.00","is_serialized":true,"warranty_months":12,"eta_item_code":"EG-674859545-T4PH","eta_item_type":"EGS"}') phone;
SELECT public.post_stock_adjustment((SELECT id FROM public.branches WHERE organization_id=(SELECT (result->>'organization_id')::uuid FROM fixture)),'found',NULL,jsonb_build_array(jsonb_build_object('product_id',(SELECT chair FROM products),'quantity',2)),'test4-stock-${stamp}');
SELECT public.register_units((SELECT phone FROM products),(SELECT id FROM public.branches WHERE organization_id=(SELECT (result->>'organization_id')::uuid FROM fixture)),'3000.00','["${serial}"]',NULL,'test4-units-${stamp}');
SELECT public.create_cash_account('TEST4 Bank','bank',NULL);
SELECT public.set_eta_settings('preprod','int4-fake-client','int4-fake-secret','4753',true);
SELECT json_build_object('orgId',(SELECT result->>'organization_id' FROM fixture),'branchId',(SELECT id FROM public.branches WHERE organization_id=(SELECT (result->>'organization_id')::uuid FROM fixture)),'email','${email}','serial','${serial}')::text;
COMMIT;`;
const result = spawnSync(
  'docker',
  [
    'exec',
    '-i',
    process.env.SUPABASE_DB_CONTAINER ?? 'supabase_db_ecofin-api',
    'psql',
    '-X',
    '-q',
    '-At',
    '-U',
    'postgres',
    '-d',
    'postgres',
    '-v',
    'ON_ERROR_STOP=1',
  ],
  { input: sql, encoding: 'utf8', timeout: 30000 },
);
if (result.status !== 0) throw new Error(result.stderr || String(result.error));
const output = result.stdout.split(/\r?\n/).find((line) => line.startsWith('{"orgId"'));
if (!output) throw new Error('Fixture result missing');
console.log(output);
