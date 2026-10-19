// N07 against local Supabase (RUN_INTEGRATION=1): a fresh shop sells two TVs on installments (N02).
// Over HTTP: a cashier reads the documents of a contract (no cash price, full national ID, 12 notes
// summing to the price, no-store), two prints at once get two different numbers (original, then
// copy), the notes mode and the terms text are saved through PATCH /api/settings (forbidden wording
// and unknown placeholders are refused with details), an accountant is refused, and another shop's
// contract is not found. (Every edge: supabase/tests/n07_printed_documents_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ContractDocumentPrint,
  ContractDocuments,
  ErrorResponse,
  ShopSettings,
  sumMoney,
  InstallmentSale,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N07 contract changes against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let manager: string;
  let accountant: string;
  let org: string;
  let branch: string;
  let tv: string;
  let version: number;
  const sales: InstallmentSale[] = [];
  let ip = 0;
  let pos = '';
  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n07-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'BRANCH_MANAGER' | 'ACCOUNTANT', tag: string) {
    const email = `n07.${tag}.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email,
        full_name: `N07 ${tag}`,
        role,
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    return login(email);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n07.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N07 shop',
        tenant_slug: `n07-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    cashier = await addEmployee('CASHIER', 'cashier');
    manager = await addEmployee('BRANCH_MANAGER', 'manager');
    accountant = await addEmployee('ACCOUNTANT', 'accountant');

    const settings = await call('patch', '/api/settings', owner, {
      prices_include_vat: true,
      credit_min_score: 0,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [{ up_to_months: 24, pct: 20 }],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
      early_settlement_rule: 'waive_future_profit',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    version = (current.body as { installment_policy: { version: number } }).installment_policy
      .version;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `N07-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 3 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const opened = await call(
      'post',
      '/api/shifts',
      manager,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    for (const n of [1, 2]) {
      const created = await call('post', '/api/customers', owner, {
        full_name: `N07 customer ${n} ${STAMP}`,
        phones: [`0150000081${n}`],
        national_id: `2900101010081${n}`,
      });
      expect(created.status, JSON.stringify(created.body)).toBe(201);
      const customerId = (created.body as { id: string }).id;
      const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
        credit_limit: '100000.00',
        reason: 'N07 integration',
      });
      expect(limit.status, JSON.stringify(limit.body)).toBe(200);
      const sold = await call(
        'post',
        '/api/installments/sales',
        manager,
        {
          lines: [{ product_id: tv, quantity: 1 }],
          expected_total: '12000.00',
          customer_id: customerId,
          terms: {
            down_payment: '2000.00',
            installments_count: 12,
            frequency: 'monthly',
            policy_version: version,
          },
        },
        key(`sale-${n}`),
      );
      expect(sold.status, JSON.stringify(sold.body)).toBe(201);
      sales.push(InstallmentSale.parse(sold.body));
    }
  }, 180_000);

  it('a cashier reads the documents: the price only, the full national ID, notes that sum to the price', async () => {
    const sale = sales[0]!;
    const res = await call('get', `/api/contracts/${sale.contract.id}/documents`, cashier);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.headers['cache-control']).toContain('no-store');
    const docs = ContractDocuments.parse(res.body);
    expect(JSON.stringify(res.body)).not.toContain('cash_price');
    expect(docs.customer.national_id).toBe('29001010100811');
    expect(docs.contract.total_payable).toBe(sale.contract.total_payable);
    expect(docs.contract.lines).toEqual(sale.contract.lines);
    expect(docs.notes).toHaveLength(12);
    expect(sumMoney(docs.notes.map((n) => n.amount))).toBe(sale.contract.balance.remaining);
    expect(docs.prints.contract).toEqual({ next_print_no: 1, copy: false });
    expect(docs.terms).toEqual({ text: null, is_default: true });
  });

  it('two prints at once get two different numbers: an original and a copy', async () => {
    const id = sales[0]!.contract.id;
    const body = { document: 'contract' };
    const [a, b] = await Promise.all([
      call('post', `/api/contracts/${id}/document-prints`, cashier, body),
      call('post', `/api/contracts/${id}/document-prints`, manager, body),
    ]);
    expect(a.status, JSON.stringify(a.body)).toBe(200);
    expect(b.status, JSON.stringify(b.body)).toBe(200);
    const prints = [ContractDocumentPrint.parse(a.body), ContractDocumentPrint.parse(b.body)];
    expect(prints.map((p) => p.print_no).sort()).toEqual([1, 2]);
    expect(prints.filter((p) => !p.copy)).toHaveLength(1);
    const after = await call('get', `/api/contracts/${id}/documents`, manager);
    expect(ContractDocuments.parse(after.body).prints.contract).toEqual({
      next_print_no: 3,
      copy: true,
    });
    const notes = await call('post', `/api/contracts/${id}/document-prints`, cashier, {
      document: 'promissory_notes',
    });
    expect(ContractDocumentPrint.parse(notes.body)).toEqual({ print_no: 1, copy: false });
  });

  it('refuses a bad body, an accountant, and an unknown contract', async () => {
    const id = sales[0]!.contract.id;
    const bad = await call('post', `/api/contracts/${id}/document-prints`, cashier, {
      document: 'receipt',
    });
    expect(bad.status).toBe(400);
    const extra = await call('post', `/api/contracts/${id}/document-prints`, cashier, {
      document: 'contract',
      organization_id: org,
    });
    expect(extra.status).toBe(400);
    const denied = await call('get', `/api/contracts/${id}/documents`, accountant);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const deniedPrint = await call('post', `/api/contracts/${id}/document-prints`, accountant, {
      document: 'contract',
    });
    expect(deniedPrint.status).toBe(403);
    const missing = await call(
      'get',
      '/api/contracts/00000000-0000-4000-8000-0000000c0777/documents',
      cashier,
    );
    expect(missing.status).toBe(404);
    expect(code(missing)).toBe('CONTRACT_NOT_FOUND');
  });

  it('saves the notes mode and the terms text; refuses forbidden wording and unknown placeholders', async () => {
    const forbidden = await call('patch', '/api/settings', owner, {
      contract_terms: 'يدفع العميل فائدة شهرية',
    });
    expect(forbidden.status).toBe(422);
    expect(code(forbidden)).toBe('TEMPLATE_NOT_ALLOWED');
    expect(ErrorResponse.parse(forbidden.body).error.details).toEqual({ words: ['فائدة'] });
    const unknown = await call('patch', '/api/settings', owner, {
      contract_terms: 'العميل {{customer_nam}}',
    });
    expect(unknown.status).toBe(422);
    expect(code(unknown)).toBe('TEMPLATE_INVALID');
    expect(ErrorResponse.parse(unknown.body).error.details).toEqual({ unknown: ['customer_nam'] });
    const cashierTries = await call('patch', '/api/settings', cashier, {
      promissory_notes_mode: 'single',
    });
    expect(cashierTries.status).toBe(403);

    const saved = await call('patch', '/api/settings', owner, {
      promissory_notes_mode: 'single',
      contract_terms: 'العميل {{customer_name}} يلتزم بسداد {{installment_price}}',
    });
    expect(saved.status, JSON.stringify(saved.body)).toBe(200);
    const settings = ShopSettings.parse((await call('get', '/api/settings', owner)).body);
    expect(settings.promissory_notes_mode).toBe('single');
    expect(settings.contract_terms).toContain('{{customer_name}}');

    const sale = sales[1]!;
    const docs = ContractDocuments.parse(
      (await call('get', `/api/contracts/${sale.contract.id}/documents`, cashier)).body,
    );
    expect(docs.terms.is_default).toBe(false);
    expect(docs.notes).toHaveLength(1);
    expect(docs.notes[0]!.amount).toBe(sale.contract.balance.remaining);
    expect(docs.notes[0]!.due_date).toBe(sale.contract.last_due_date);

    const reset = await call('patch', '/api/settings', owner, {
      contract_terms: null,
      promissory_notes_mode: 'per_installment',
    });
    expect(reset.status, JSON.stringify(reset.body)).toBe(200);
  });
});
