// L01 + N09 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): two fresh
// shops with the legal module sell a TV on installments (N02) and a third shop has no legal module.
// Over HTTP: the owner opens a case from a legal referral (the customer is blocked, the referral
// becomes case_opened, the contract carries the flag), a second open and a claim above what is owed
// are refused, a cashier and a lawyer can't open, an assigned lawyer works their own case and a
// colleague gets not found everywhere (the case, its hearings, notes and papers), a lawyer is refused
// on sales, cash and reports, shop B's owner can't reach shop A's real case, and nothing a case
// does changes what is owed. (The rules themselves: supabase/tests/l01_legal_module_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  Contract,
  ErrorResponse,
  FileListResponse,
  FileResponse,
  InstallmentSale,
  LawyerListResponse,
  LegalCaseDetail,
  LegalCaseListResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(5)]);

interface Shop {
  tag: string;
  org: string;
  branch: string;
  owner: string;
  pos: string;
  cashier: string;
  tv: string;
  version: number;
}

describe.skipIf(!RUN)('L01 legal module against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let a: Shop;
  let b: Shop;
  let c: Shop;
  let ip = 0;
  let nationalId = 0;
  const key = (tag: string) => `l01-it-${tag}-${STAMP}`;
  const call = (
    shop: Shop,
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    idempotencyKey?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token)
      .set('x-org-id', shop.org);
    if (shop.pos) r.set(DEVICE_TOKEN_HEADER, shop.pos);
    if (idempotencyKey) r.set('Idempotency-Key', idempotencyKey);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(
    shop: Shop,
    role: 'CASHIER' | 'LAWYER' | 'BRANCH_MANAGER',
    tag: string,
  ): Promise<{ token: string; id: string }> {
    const email = `l01.${shop.tag}.${tag}.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: shop.org,
        auth_user_id: user.data.user!.id,
        email,
        phone: '0100000' + String(++nationalId).padStart(4, '0'),
        full_name: `L01 ${tag}`,
        role,
        default_branch_id: shop.branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: shop.org, employee_id: emp.data!.id, branch_id: shop.branch });
    return { token: await login(email), id: emp.data!.id as string };
  }
  async function makeShop(tag: string, plan: string, sells: boolean): Promise<Shop> {
    const admin = await login('superadmin@ecotech.test');
    const email = `l01.owner.${tag}.${STAMP}@ecotech.test`;
    const created = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `L01 shop ${tag}`,
        tenant_slug: `l01-${tag}-${STAMP}`,
        plan_key: plan,
        owner: { full_name: 'Owner', email },
      });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const org = created.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    const owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    const shop: Shop = {
      tag,
      org,
      branch: main.data!.id as string,
      owner,
      pos: '',
      cashier: '',
      tv: '',
      version: 0,
    };
    if (!sells) return shop;
    shop.pos = (await pairTestDevice(service, org, shop.branch)).token;
    shop.cashier = (await addEmployee(shop, 'CASHIER', 'cashier')).token;
    const settings = await call(shop, 'patch', '/api/settings', owner, {
      prices_include_vat: true,
      credit_min_score: 0,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const published = await call(shop, 'post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [{ up_to_months: 24, pct: 20 }],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
      grace_days: 3,
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call(shop, 'get', '/api/settings', owner);
    shop.version = (
      current.body as { installment_policy: { version: number } }
    ).installment_policy.version;
    const product = await call(shop, 'post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `L01-TV-${tag}-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    shop.tv = (product.body as { id: string }).id;
    const stocked = await call(
      shop,
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: shop.branch, reason: 'found', lines: [{ product_id: shop.tv, quantity: 12 }] },
      key('stock-' + tag),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const opened = await call(
      shop,
      'post',
      '/api/shifts',
      shop.cashier,
      { branch_id: shop.branch, opening_float: '0' },
      key('shift-' + tag),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    return shop;
  }
  /** A new installment contract of a new customer (N02), optionally with an open legal referral. */
  async function contractOf(shop: Shop, withReferral: boolean) {
    const n = ++nationalId;
    const created = await call(shop, 'post', '/api/customers', shop.owner, {
      full_name: `L01 customer ${shop.tag} ${n}`,
      phones: ['0150000' + String(n).padStart(4, '0')],
      national_id: '2900101010' + String(n).padStart(4, '0'),
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const customerId = (created.body as { id: string }).id;
    const limit = await call(shop, 'put', `/api/customers/${customerId}/credit-limit`, shop.owner, {
      credit_limit: '100000.00',
      reason: 'L01 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    const sold = await call(
      shop,
      'post',
      '/api/installments/sales',
      shop.cashier,
      {
        lines: [{ product_id: shop.tv, quantity: 1 }],
        expected_total: '12000.00',
        customer_id: customerId,
        terms: {
          down_payment: '2000.00',
          installments_count: 12,
          frequency: 'monthly',
          policy_version: shop.version,
        },
      },
      key(`sale-${shop.tag}-${n}`),
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    const sale = InstallmentSale.parse(sold.body);
    let referralId: string | null = null;
    if (withReferral) {
      const line = await service
        .from('schedule_lines')
        .select('id')
        .eq('contract_id', sale.contract.id)
        .order('seq')
        .limit(1)
        .single();
      expect(line.error).toBeNull();
      const made = await service
        .from('overdue_actions')
        .insert({
          organization_id: shop.org,
          kind: 'legal_referral',
          contract_id: sale.contract.id,
          customer_id: customerId,
          branch_id: shop.branch,
          schedule_line_id: (line.data as { id: string }).id,
          business_date: new Date().toISOString().slice(0, 10),
          days_late: 70,
          overdue_amount: '1000.00',
          status: 'open',
        })
        .select('id')
        .single();
      expect(made.error).toBeNull();
      referralId = (made.data as { id: string }).id;
    }
    return { contractId: sale.contract.id, customerId, referralId };
  }
  async function owed(contractId: string) {
    const { data, error } = await service
      .from('v_contract_balances')
      .select('total_payable, paid, remaining')
      .eq('contract_id', contractId)
      .single();
    expect(error).toBeNull();
    return data;
  }
  async function openCase(shop: Shop, contractId: string, extra: object = {}, tag = 'open') {
    const res = await call(
      shop,
      'post',
      '/api/legal/cases',
      shop.owner,
      { contract_id: contractId, ...extra },
      key(`${tag}-${contractId}`),
    );
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return LegalCaseDetail.parse(res.body);
  }

  let lawyerA1: { token: string; id: string };
  let lawyerA2: { token: string; id: string };
  let cashierA: string;
  let contractA: string;
  let customerA: string;
  let caseA: LegalCaseDetail;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    a = await makeShop('a', 'retail_pro', true);
    b = await makeShop('b', 'retail_pro', true);
    c = await makeShop('c', 'retail', false);
    lawyerA1 = await addEmployee(a, 'LAWYER', 'lawyer1');
    lawyerA2 = await addEmployee(a, 'LAWYER', 'lawyer2');
    cashierA = a.cashier;
  }, 240_000);

  it('opens a case from a legal referral: the referral, the customer and the contract flag follow', async () => {
    const f = await contractOf(a, true);
    contractA = f.contractId;
    customerA = f.customerId;
    const before = await owed(contractA);
    caseA = await openCase(a, contractA, {
      lawyer_employee_id: lawyerA1.id,
      court: 'Cairo Economic Court',
      case_number: `${STAMP}/2026`,
      note: 'First note',
    });
    expect(caseA.status).toBe('preparing');
    expect(Number(caseA.claim_amount)).toBe(Number(before!.remaining));
    expect(caseA.referral?.id).toBe(f.referralId);
    expect(caseA.notes).toHaveLength(1);
    expect(caseA.customer.status).toBe('blocked');

    const referral = await service
      .from('overdue_actions')
      .select('status, legal_case_id')
      .eq('id', f.referralId!)
      .single();
    expect(referral.data).toEqual({ status: 'case_opened', legal_case_id: caseA.id });

    const flagged = await call(a, 'get', `/api/contracts/${contractA}`, a.owner);
    expect(flagged.status, JSON.stringify(flagged.body)).toBe(200);
    expect(Contract.parse(flagged.body).legal_case).toMatchObject({
      id: caseA.id,
      status: 'preparing',
    });
    expect(await owed(contractA)).toEqual(before);
  });

  it('the same key and body is the same case; a second open and a claim above what is owed are refused', async () => {
    const again = await call(
      a,
      'post',
      '/api/legal/cases',
      a.owner,
      {
        contract_id: contractA,
        lawyer_employee_id: lawyerA1.id,
        court: 'Cairo Economic Court',
        case_number: `${STAMP}/2026`,
        note: 'First note',
      },
      key(`open-${contractA}`),
    );
    expect(again.status, JSON.stringify(again.body)).toBe(201);
    expect(LegalCaseDetail.parse(again.body).id).toBe(caseA.id);

    const other = await call(
      a,
      'post',
      '/api/legal/cases',
      a.owner,
      { contract_id: contractA, court: 'Another court' },
      key(`open-${contractA}`),
    );
    expect(other.status).toBe(409);
    expect(code(other)).toBe('IDEMPOTENCY_CONFLICT');

    const second = await call(
      a,
      'post',
      '/api/legal/cases',
      a.owner,
      { contract_id: contractA },
      key('second-open'),
    );
    expect(second.status).toBe(409);
    expect(code(second)).toBe('LEGAL_CASE_ALREADY_OPEN');
    expect(ErrorResponse.parse(second.body).error.details).toEqual({ legal_case_id: caseA.id });

    const high = await call(a, 'patch', `/api/legal/cases/${caseA.id}`, a.owner, {
      claim_amount: '99999999.00',
    });
    expect(high.status).toBe(422);
    expect(code(high)).toBe('LEGAL_CLAIM_TOO_HIGH');
    expect(ErrorResponse.parse(high.body).error.details).toEqual({
      remaining: caseA.amounts.remaining,
    });
  });

  it('a contract with nothing overdue and no referral can not be sent to court', async () => {
    const f = await contractOf(a, false);
    const res = await call(
      a,
      'post',
      '/api/legal/cases',
      a.owner,
      { contract_id: f.contractId },
      key('not-defaulted'),
    );
    expect(res.status).toBe(422);
    expect(code(res)).toBe('LEGAL_CONTRACT_NOT_DEFAULTED');
  });

  it('only the owner opens or assigns; a cashier reads nothing; a lawyer is refused', async () => {
    const f = await contractOf(a, true);
    const body = { contract_id: f.contractId };
    const asCashier = await call(a, 'post', '/api/legal/cases', cashierA, body, key('cashier'));
    expect(asCashier.status).toBe(403);
    expect(code(asCashier)).toBe('PERMISSION_DENIED');
    const asLawyer = await call(a, 'post', '/api/legal/cases', lawyerA1.token, body, key('lawyer'));
    expect(asLawyer.status).toBe(403);
    expect(code(asLawyer)).toBe('PERMISSION_DENIED');
    const list = await call(a, 'get', '/api/legal/cases', cashierA);
    expect(list.status).toBe(403);
    const reassign = await call(a, 'patch', `/api/legal/cases/${caseA.id}`, lawyerA1.token, {
      lawyer_employee_id: lawyerA2.id,
    });
    expect(reassign.status).toBe(403);
    const bad = await call(
      a,
      'post',
      '/api/legal/cases',
      a.owner,
      {
        ...body,
        lawyer_employee_id: (await addEmployee(a, 'CASHIER', 'notalawyer')).id,
      },
      key('bad-lawyer'),
    );
    expect(bad.status).toBe(422);
    expect(code(bad)).toBe('LAWYER_INVALID');
  });

  it('the owner picks from the lawyers; a lawyer can not', async () => {
    const list = await call(a, 'get', '/api/legal/lawyers', a.owner);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    const lawyers = LawyerListResponse.parse(list.body).items;
    expect(lawyers.map((l) => l.id).sort()).toEqual([lawyerA1.id, lawyerA2.id].sort());
    expect(lawyers.find((l) => l.id === lawyerA1.id)?.open_cases).toBeGreaterThanOrEqual(1);
    const refused = await call(a, 'get', '/api/legal/lawyers', lawyerA1.token);
    expect(refused.status).toBe(403);
  });

  it('the assigned lawyer works the case; a colleague gets not found on everything', async () => {
    const mine = await call(a, 'get', '/api/legal/cases?status=all', lawyerA1.token);
    expect(mine.status, JSON.stringify(mine.body)).toBe(200);
    expect(LegalCaseListResponse.parse(mine.body).rows.map((r) => r.id)).toContain(caseA.id);
    const theirs = await call(a, 'get', '/api/legal/cases?status=all', lawyerA2.token);
    expect(LegalCaseListResponse.parse(theirs.body).rows.map((r) => r.id)).not.toContain(caseA.id);

    const hearing = await call(a, 'post', `/api/legal/cases/${caseA.id}/hearings`, lawyerA1.token, {
      hearing_date: '2031-03-01',
      notes: 'First hearing',
    });
    expect(hearing.status, JSON.stringify(hearing.body)).toBe(200);
    const detail = LegalCaseDetail.parse(hearing.body);
    expect(detail.hearings).toHaveLength(1);
    const hearingId = detail.hearings[0]!.id;
    const outcome = await call(
      a,
      'patch',
      `/api/legal/cases/${caseA.id}/hearings/${hearingId}`,
      lawyerA1.token,
      { outcome: 'Adjourned' },
    );
    expect(outcome.status, JSON.stringify(outcome.body)).toBe(200);
    const note = await call(a, 'post', `/api/legal/cases/${caseA.id}/notes`, lawyerA1.token, {
      note: 'Spoke to the guarantor',
    });
    expect(LegalCaseDetail.parse(note.body).notes).toHaveLength(2);
    const filed = await call(a, 'post', `/api/legal/cases/${caseA.id}/status`, lawyerA1.token, {
      status: 'filed',
    });
    expect(filed.status, JSON.stringify(filed.body)).toBe(200);
    expect(LegalCaseDetail.parse(filed.body).status).toBe('filed');
    const jump = await call(a, 'post', `/api/legal/cases/${caseA.id}/status`, lawyerA1.token, {
      status: 'preparing',
    });
    expect(jump.status).toBe(409);
    expect(code(jump)).toBe('LEGAL_STATUS_INVALID');
    expect(ErrorResponse.parse(jump.body).error.details).toEqual({
      from: 'filed',
      to: 'preparing',
    });

    const colleague = lawyerA2.token;
    const attempts = [
      call(a, 'get', `/api/legal/cases/${caseA.id}`, colleague),
      call(a, 'patch', `/api/legal/cases/${caseA.id}`, colleague, { court: 'Mine now' }),
      call(a, 'post', `/api/legal/cases/${caseA.id}/status`, colleague, { status: 'in_court' }),
      call(a, 'post', `/api/legal/cases/${caseA.id}/hearings`, colleague, {
        hearing_date: '2031-04-01',
      }),
      call(a, 'patch', `/api/legal/cases/${caseA.id}/hearings/${hearingId}`, colleague, {
        outcome: 'x',
      }),
      call(a, 'post', `/api/legal/cases/${caseA.id}/notes`, colleague, { note: 'Not mine' }),
    ];
    for (const res of await Promise.all(attempts)) {
      expect(res.status, JSON.stringify(res.body)).toBe(404);
      expect(code(res)).toBe('LEGAL_CASE_NOT_FOUND');
    }
    const wrongHearing = await call(
      a,
      'patch',
      `/api/legal/cases/${caseA.id}/hearings/${caseA.id}`,
      lawyerA1.token,
      { outcome: 'x' },
    );
    expect(wrongHearing.status).toBe(404);
    expect(code(wrongHearing)).toBe('HEARING_NOT_FOUND');
  });

  it('the papers of a case: the assigned lawyer uploads and lists them; a colleague can not list, open or add', async () => {
    const up = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + lawyerA1.token)
      .set('x-org-id', a.org)
      .field('purpose', 'legal_document')
      .field('entityType', 'legal_case')
      .field('entityId', caseA.id)
      .attach('file', PNG, { filename: 'claim.png', contentType: 'image/png' });
    expect(up.status, JSON.stringify(up.body)).toBe(201);
    const file = FileResponse.parse(up.body);
    const own = await call(
      a,
      'get',
      `/api/files?entityType=legal_case&entityId=${caseA.id}`,
      lawyerA1.token,
    );
    expect(own.status, JSON.stringify(own.body)).toBe(200);
    expect(FileListResponse.parse(own.body).items.map((f) => f.id)).toContain(file.id);
    const url = await call(a, 'get', `/api/files/${file.id}/url`, lawyerA1.token);
    expect(url.status, JSON.stringify(url.body)).toBe(200);

    const list = await call(
      a,
      'get',
      `/api/files?entityType=legal_case&entityId=${caseA.id}`,
      lawyerA2.token,
    );
    expect(list.status).toBe(404);
    expect(code(list)).toBe('LEGAL_CASE_NOT_FOUND');
    const link = await call(a, 'get', `/api/files/${file.id}/url`, lawyerA2.token);
    expect(link.status).toBe(404);
    expect(code(link)).toBe('LEGAL_CASE_NOT_FOUND');
    const add = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + lawyerA2.token)
      .set('x-org-id', a.org)
      .field('purpose', 'legal_document')
      .field('entityType', 'legal_case')
      .field('entityId', caseA.id)
      .attach('file', PNG, { filename: 'claim.png', contentType: 'image/png' });
    expect(add.status).toBe(404);
    expect(ErrorResponse.parse(add.body).error.code).toBe('LEGAL_CASE_NOT_FOUND');
    const ownerList = await call(
      a,
      'get',
      `/api/files?entityType=legal_case&entityId=${caseA.id}`,
      a.owner,
    );
    expect(ownerList.status).toBe(200);
  });

  it('a lawyer is refused on sales, returns, quotations, shifts, cash, expenses and reports', async () => {
    for (const path of [
      '/api/sales',
      '/api/returns',
      '/api/quotations',
      '/api/shifts',
      '/api/cash-accounts',
      '/api/cash-transfers',
      '/api/expenses',
      '/api/reports/sales?from=2026-10-01&to=2026-10-02&group_by=day',
      '/api/reports/receivables?group_by=customer',
    ]) {
      const res = await call(a, 'get', path, lawyerA1.token);
      expect(res.status, path + JSON.stringify(res.body)).toBe(403);
      expect(code(res), path).toBe('PERMISSION_DENIED');
    }
    // What a lawyer needs stays open: the contract of the case and the overdue list (read only).
    expect((await call(a, 'get', `/api/contracts/${contractA}`, lawyerA1.token)).status).toBe(200);
    expect((await call(a, 'get', '/api/overdue', lawyerA1.token)).status).toBe(200);
  });

  it('closing records the outcome, changes nothing that is owed and keeps the customer blocked', async () => {
    const before = await owed(contractA);
    const closedRes = await call(a, 'post', `/api/legal/cases/${caseA.id}/status`, a.owner, {
      status: 'closed',
      outcome_kind: 'settled_out_of_court',
      outcome: 'A plan agreed at the court',
    });
    expect(closedRes.status, JSON.stringify(closedRes.body)).toBe(200);
    const closed = LegalCaseDetail.parse(closedRes.body);
    expect(closed).toMatchObject({ status: 'closed', outcome_kind: 'settled_out_of_court' });
    expect(closed.closed_at).not.toBeNull();
    expect(await owed(contractA)).toEqual(before);
    const customer = await service.from('customers').select('status').eq('id', customerA).single();
    expect(customer.data!.status).toBe('blocked');
    const flagged = await call(a, 'get', `/api/contracts/${contractA}`, a.owner);
    expect(Contract.parse(flagged.body).legal_case).toBeNull();
    const reopen = await call(a, 'post', `/api/legal/cases/${caseA.id}/status`, a.owner, {
      status: 'in_court',
    });
    expect(reopen.status).toBe(409);
    const edit = await call(a, 'patch', `/api/legal/cases/${caseA.id}`, a.owner, { court: 'Late' });
    expect(edit.status).toBe(409);
    expect(code(edit)).toBe('LEGAL_CASE_CLOSED');
    const note = await call(a, 'post', `/api/legal/cases/${caseA.id}/notes`, a.owner, {
      note: 'Follow-up after the close',
    });
    expect(note.status).toBe(200);
  });

  it("shop B can't reach shop A's real case, hearing or contract; shop A's header is refused", async () => {
    const f = await contractOf(a, true);
    const real = await openCase(a, f.contractId, { lawyer_employee_id: lawyerA1.id }, 'iso');
    const hearing = await call(a, 'post', `/api/legal/cases/${real.id}/hearings`, a.owner, {
      hearing_date: '2031-05-01',
    });
    const hearingId = LegalCaseDetail.parse(hearing.body).hearings[0]!.id;
    const attempts = [
      call(b, 'get', `/api/legal/cases/${real.id}`, b.owner),
      call(b, 'patch', `/api/legal/cases/${real.id}`, b.owner, { court: 'Theirs' }),
      call(b, 'post', `/api/legal/cases/${real.id}/status`, b.owner, { status: 'filed' }),
      call(b, 'post', `/api/legal/cases/${real.id}/hearings`, b.owner, {
        hearing_date: '2031-06-01',
      }),
      call(b, 'patch', `/api/legal/cases/${real.id}/hearings/${hearingId}`, b.owner, {
        outcome: 'x',
      }),
      call(b, 'post', `/api/legal/cases/${real.id}/notes`, b.owner, { note: 'Not yours' }),
    ];
    for (const res of await Promise.all(attempts)) {
      expect(res.status, JSON.stringify(res.body)).toBe(404);
      expect(code(res)).toBe('LEGAL_CASE_NOT_FOUND');
    }
    const open = await call(
      b,
      'post',
      '/api/legal/cases',
      b.owner,
      { contract_id: f.contractId },
      key('iso-open'),
    );
    expect(open.status).toBe(404);
    expect(code(open)).toBe('CONTRACT_NOT_FOUND');
    const listB = await call(b, 'get', '/api/legal/cases?status=all', b.owner);
    expect(LegalCaseListResponse.parse(listB.body).rows.map((r) => r.id)).not.toContain(real.id);
    const files = await call(
      b,
      'get',
      `/api/files?entityType=legal_case&entityId=${real.id}`,
      b.owner,
    );
    expect(files.status).toBe(404);
    expect(code(files)).toBe('LEGAL_CASE_NOT_FOUND');
    const foreign = await request(app)
      .get(`/api/legal/cases/${real.id}`)
      .set('X-Forwarded-For', `198.18.101.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + b.owner)
      .set('x-org-id', a.org);
    expect(foreign.status).toBe(403);
    expect(code(foreign)).toBe('SHOP_NOT_ALLOWED');
  });

  it('a shop whose plan has no legal module gets MODULE_NOT_IN_PLAN', async () => {
    const list = await call(c, 'get', '/api/legal/cases', c.owner);
    expect(list.status, JSON.stringify(list.body)).toBe(403);
    expect(code(list)).toBe('MODULE_NOT_IN_PLAN');
    const lawyers = await call(c, 'get', '/api/legal/lawyers', c.owner);
    expect(code(lawyers)).toBe('MODULE_NOT_IN_PLAN');
  });
});
