// K03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner funds the main safe; an accountant keeps the categories and pays an
// expense from the safe (one key, twice: one expense); the owner pays one from an open shift and
// reverses both (the second after the shift closed, into the safe); the safe adds up.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  ErrorResponse,
  Expense,
  ExpenseCategory,
  ExpenseCategoryList,
  ExpenseList,
  ExpenseReport,
  Shift,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const day = (offset: number) => new Date(STAMP + offset * 86_400_000).toISOString().slice(0, 10);

describe.skipIf(!RUN)('K03 expenses against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let accountant: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let ip = 0;
  // O03: the paired POS computer every request of this test comes from.
  let pos = '';
  const call = (
    method: 'get' | 'post' | 'patch',
    path: string,
    token: string,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.61.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.61.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const safe = async () =>
    CashAccount.parse((await call('get', `/api/cash-accounts/${mainSafe}`, owner)).body).balance;
  async function staff(role: 'ACCOUNTANT' | 'CASHIER') {
    const email = `k03.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
        full_name: `K03 ${role}`,
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
    const email = `k03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.61.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'K03 shop',
        tenant_slug: `k03-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.61.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service
      .from('branches')
      .select('id, default_cash_account_id')
      .eq('organization_id', org)
      .single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    mainSafe = main.data!.default_cash_account_id as string;
    accountant = await staff('ACCOUNTANT');
    cashier = await staff('CASHIER');

    const opened = await call(
      'post',
      `/api/cash-accounts/${mainSafe}/opening`,
      owner,
      { amount: '5000.00', note: 'Counted on day one' },
      `k03-it-open-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(200);
  }, 60_000);

  it('categories, an expense from the safe and from a shift, owner reversals; the safe adds up', async () => {
    // A cashier has none of the keys.
    expect((await call('post', '/api/expense-categories', cashier, { name: 'Rent' })).status).toBe(
      403,
    );
    expect((await call('get', '/api/expenses', cashier)).status).toBe(403);

    const made = await call('post', '/api/expense-categories', accountant, { name: ' Rent ' });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const rent = ExpenseCategory.parse(made.body);
    expect(rent.name).toBe('Rent');
    const twice = await call('post', '/api/expense-categories', accountant, { name: 'Rent' });
    expect(twice.status).toBe(409);
    expect(code(twice)).toBe('EXPENSE_CATEGORY_NAME_TAKEN');
    const renamed = await call('patch', `/api/expense-categories/${rent.id}`, accountant, {
      name: 'Shop rent',
    });
    expect(ExpenseCategory.parse(renamed.body).name).toBe('Shop rent');

    // From the safe: the key and one source are required; one key spends once.
    const body = { category_id: rent.id, amount: '150.00', branch_id: branch };
    const vaultBody = { ...body, cash_account_id: mainSafe, note: 'October' };
    expect((await call('post', '/api/expenses', accountant, vaultBody)).status).toBe(400);
    expect(
      (await call('post', '/api/expenses', accountant, body, `k03-none-${STAMP}`)).status,
    ).toBe(400);
    const key = `k03-it-expense-${STAMP}`;
    const [first, second] = await Promise.all([
      call('post', '/api/expenses', accountant, vaultBody, key),
      call('post', '/api/expenses', accountant, vaultBody, key),
    ]);
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    expect(second.status, JSON.stringify(second.body)).toBe(201);
    const paid = Expense.parse(first.body);
    expect(Expense.parse(second.body).id).toBe(paid.id);
    expect(paid).toMatchObject({
      amount: '150.00',
      category_name: 'Shop rent',
      cash_account_kind: 'safe',
      shift_id: null,
      note: 'October',
    });
    expect(paid.number).toContain('-EX-');
    expect(await safe()).toBe('4850.00');
    const tooMuch = await call(
      'post',
      '/api/expenses',
      accountant,
      { ...vaultBody, amount: '4850.01' },
      `k03-it-much-${STAMP}`,
    );
    expect(tooMuch.status).toBe(409);
    expect(code(tooMuch)).toBe('INSUFFICIENT_FUNDS');

    // From the open shift: the accountant has none; the owner opens one with 100.00.
    const noShift = await call(
      'post',
      '/api/expenses',
      accountant,
      { category_id: rent.id, amount: '30.00', from_shift: true },
      `k03-it-noshift-${STAMP}`,
    );
    expect(noShift.status).toBe(409);
    expect(code(noShift)).toBe('SHIFT_REQUIRED');
    const opened = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: branch, opening_float: '100.00', vault_id: mainSafe },
      `k03-it-shift-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const shift = Shift.parse(opened.body);
    const fromShift = await call(
      'post',
      '/api/expenses',
      owner,
      { category_id: rent.id, amount: '30.00', from_shift: true, note: 'Taxi' },
      `k03-it-drawer-${STAMP}`,
    );
    expect(fromShift.status, JSON.stringify(fromShift.body)).toBe(201);
    const taxi = Expense.parse(fromShift.body);
    expect(taxi).toMatchObject({ shift_id: shift.id, cash_account_kind: 'drawer' });
    expect(
      Shift.parse((await call('get', `/api/shifts/${shift.id}`, owner)).body).expected_cash,
    ).toBe('70.00');
    expect(await safe()).toBe('4750.00');

    // An archived category takes no expense.
    const archived = await call('post', `/api/expense-categories/${rent.id}/archive`, accountant);
    expect(ExpenseCategory.parse(archived.body).archived_at).not.toBeNull();
    const refused = await call(
      'post',
      '/api/expenses',
      accountant,
      vaultBody,
      `k03-it-arch-${STAMP}`,
    );
    expect(refused.status).toBe(409);
    expect(code(refused)).toBe('EXPENSE_CATEGORY_ARCHIVED');
    expect(
      ExpenseCategoryList.parse((await call('get', '/api/expense-categories', accountant)).body),
    ).toHaveLength(0);
    const restored = await call('post', `/api/expense-categories/${rent.id}/restore`, accountant);
    expect(ExpenseCategory.parse(restored.body).archived_at).toBeNull();

    // Only the owner reverses; once; the same key answers the same reversal.
    const reason = { reason: 'Entered twice' };
    const denied = await call(
      'post',
      `/api/expenses/${paid.id}/reverse`,
      accountant,
      reason,
      `k03-it-rev-acc-${STAMP}`,
    );
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('APPROVAL_OWNER_ONLY');
    const revKey = `k03-it-rev-${STAMP}`;
    const reversed = await call('post', `/api/expenses/${paid.id}/reverse`, owner, reason, revKey);
    expect(reversed.status, JSON.stringify(reversed.body)).toBe(200);
    const reversal = Expense.parse(reversed.body);
    expect(reversal).toMatchObject({ reverses_expense_id: paid.id, amount: '150.00' });
    const again = await call('post', `/api/expenses/${paid.id}/reverse`, owner, reason, revKey);
    expect(Expense.parse(again.body).id).toBe(reversal.id);
    const once = await call(
      'post',
      `/api/expenses/${paid.id}/reverse`,
      owner,
      reason,
      `k03-it-rev2-${STAMP}`,
    );
    expect(once.status).toBe(409);
    expect(code(once)).toBe('EXPENSE_ALREADY_REVERSED');
    expect(await safe()).toBe('4900.00');
    expect(
      Expense.parse((await call('get', `/api/expenses/${paid.id}`, accountant)).body)
        .reversed_by_expense_id,
    ).toBe(reversal.id);

    // The list and the report count what was really spent.
    const all = ExpenseList.parse((await call('get', '/api/expenses', accountant)).body);
    expect(all.total).toBe(3);
    const counted = ExpenseList.parse(
      (await call('get', `/api/expenses?include_reversals=false&branch_id=${branch}`, accountant))
        .body,
    );
    expect(counted.items.map((x) => x.id)).toEqual([taxi.id]);
    const report = ExpenseReport.parse(
      (await call('get', `/api/expenses/report?from=${day(-1)}&to=${day(1)}`, accountant)).body,
    );
    expect(report).toMatchObject({ count: 1, total: '30.00' });
    expect(report.items).toEqual([
      { category_id: rent.id, category_name: 'Shop rent', count: 1, total: '30.00' },
    ]);

    // After the shift closed, its expense goes back into a vault.
    const closed = await call('post', `/api/shifts/${shift.id}/close`, owner, {
      counts: { '50': 1, '20': 1 },
      vault_id: mainSafe,
    });
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    const noVault = await call(
      'post',
      `/api/expenses/${taxi.id}/reverse`,
      owner,
      reason,
      `k03-it-rev3-${STAMP}`,
    );
    expect(noVault.status).toBe(400);
    expect(code(noVault)).toBe('VAULT_INVALID');
    const back = await call(
      'post',
      `/api/expenses/${taxi.id}/reverse`,
      owner,
      { ...reason, cash_account_id: mainSafe },
      `k03-it-rev4-${STAMP}`,
    );
    expect(back.status, JSON.stringify(back.body)).toBe(200);
    expect(Expense.parse(back.body)).toMatchObject({ shift_id: null, cash_account_id: mainSafe });
    // 5 000 - 150 + 150 - 100 (float) + 70 (closing) + 30 (reversal).
    expect(await safe()).toBe('5000.00');
  }, 60_000);
});
