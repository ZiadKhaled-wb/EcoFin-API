// K02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner funds the main safe; a cashier sees the branch's safes by name, opens a
// shift with a float (one key, twice: one shift), drops cash into the safe and takes change,
// closes ten pounds short with a reason, and the safe adds up; a closed shift takes no cash.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  CurrentShift,
  ErrorResponse,
  Shift,
  ShiftList,
  ShiftVaultList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('K02 shifts against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post',
    path: string,
    token = cashier,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.60.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.60.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const safe = async () =>
    CashAccount.parse((await call('get', `/api/cash-accounts/${mainSafe}`, owner)).body).balance;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `k02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.60.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'K02 shop',
        tenant_slug: `k02-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.60.${(++ip % 250) + 1}`)
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
    mainSafe = main.data!.default_cash_account_id as string;
    const cashierEmail = `k02.cashier.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: cashierEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: cashierEmail,
        full_name: 'Mona Cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    cashier = await login(cashierEmail);

    const opened = await call(
      'post',
      `/api/cash-accounts/${mainSafe}/opening`,
      owner,
      { amount: '5000.00', note: 'Counted on day one' },
      `k02-it-open-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(200);
  }, 60_000);

  it('a cashier opens a shift once, moves cash, closes short with a reason; the safe adds up', async () => {
    const vaults = ShiftVaultList.parse(
      (await call('get', `/api/shifts/vaults?branch_id=${branch}`)).body,
    );
    expect(vaults.items.map((v) => v.id)).toEqual([mainSafe]);
    expect(Object.keys(vaults.items[0]!)).toEqual(['id', 'name']);
    // A cashier doesn't see vault balances (K01 needs cash.view).
    expect((await call('get', '/api/cash-accounts')).status).toBe(403);
    expect(CurrentShift.parse((await call('get', '/api/shifts/current')).body).shift).toBeNull();

    const body = { branch_id: branch, opening_float: '500.00', vault_id: mainSafe };
    expect((await call('post', '/api/shifts', cashier, body)).status).toBe(400);
    const noSafe = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '500.00' },
      `k02-it-nosafe-${STAMP}`,
    );
    expect(noSafe.status).toBe(400);
    const key = `k02-it-${STAMP}`;
    const [first, second] = await Promise.all([
      call('post', '/api/shifts', cashier, body, key),
      call('post', '/api/shifts', cashier, body, key),
    ]);
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    expect(second.status, JSON.stringify(second.body)).toBe(201);
    const shift = Shift.parse(first.body);
    expect(Shift.parse(second.body).id).toBe(shift.id);
    expect(shift).toMatchObject({
      status: 'open',
      opening_float: '500.00',
      expected_cash: '500.00',
      employee_name: 'Mona Cashier',
    });
    expect(shift.number).toContain('SH');
    expect(await safe()).toBe('4500.00');
    const again = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      `k02-it-again-${STAMP}`,
    );
    expect(again.status).toBe(409);
    expect(code(again)).toBe('SHIFT_ALREADY_OPEN');
    expect(CurrentShift.parse((await call('get', '/api/shifts/current')).body).shift?.id).toBe(
      shift.id,
    );

    const out = await call(
      'post',
      `/api/shifts/${shift.id}/cash`,
      cashier,
      { direction: 'out', amount: '200.00', vault_id: mainSafe, note: 'Too much in the till' },
      `k02-it-out-${STAMP}`,
    );
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(Shift.parse(out.body).expected_cash).toBe('300.00');
    const into = await call(
      'post',
      `/api/shifts/${shift.id}/cash`,
      cashier,
      { direction: 'in', amount: '100.00', vault_id: mainSafe, note: 'Change' },
      `k02-it-in-${STAMP}`,
    );
    const moved = Shift.parse(into.body);
    expect(moved.expected_cash).toBe('400.00');
    expect(moved.movements.map((m) => [m.type, m.amount])).toEqual([
      ['float_in', '500.00'],
      ['float_out', '-200.00'],
      ['float_in', '100.00'],
    ]);
    expect(moved.movements.every((m) => m.source_number?.includes('CX'))).toBe(true);
    expect(await safe()).toBe('4600.00');
    const tooMuch = await call(
      'post',
      `/api/shifts/${shift.id}/cash`,
      cashier,
      { direction: 'out', amount: '401.00', vault_id: mainSafe, note: 'More than the till' },
      `k02-it-big-${STAMP}`,
    );
    expect(tooMuch.status).toBe(409);
    expect(code(tooMuch)).toBe('INSUFFICIENT_FUNDS');

    const counts = { '200': 1, '100': 1, '50': 1, '20': 2 };
    const noReason = await call('post', `/api/shifts/${shift.id}/close`, cashier, {
      counts,
      vault_id: mainSafe,
    });
    expect(noReason.status).toBe(400);
    expect(code(noReason)).toBe('SHIFT_DIFFERENCE_REASON_REQUIRED');
    expect(ErrorResponse.parse(noReason.body).error.details).toEqual({
      expected: '400.00',
      counted: '390.00',
      difference: '-10.00',
    });
    const closed = await call('post', `/api/shifts/${shift.id}/close`, cashier, {
      counts,
      vault_id: mainSafe,
      difference_reason: 'Ten pounds short',
    });
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    expect(Shift.parse(closed.body)).toMatchObject({
      status: 'closed',
      expected_cash: '400.00',
      counted_cash: '390.00',
      difference: '-10.00',
      difference_reason: 'Ten pounds short',
      closed_by_name: 'Mona Cashier',
    });
    // 5 000 - 500 + 200 - 100 + 390.
    expect(await safe()).toBe('4990.00');
    const twice = await call('post', `/api/shifts/${shift.id}/close`, cashier, { counts: {} });
    expect(Shift.parse(twice.body).counted_cash).toBe('390.00');
    expect(await safe()).toBe('4990.00');

    const late = await call(
      'post',
      `/api/shifts/${shift.id}/cash`,
      cashier,
      { direction: 'in', amount: '1.00', vault_id: mainSafe, note: 'After closing' },
      `k02-it-late-${STAMP}`,
    );
    expect(late.status).toBe(409);
    expect(code(late)).toBe('SHIFT_CLOSED');
    expect(CurrentShift.parse((await call('get', '/api/shifts/current')).body).shift).toBeNull();
    const list = ShiftList.parse((await call('get', '/api/shifts?status=closed', owner)).body);
    expect(list.items.map((s) => s.id)).toEqual([shift.id]);
    expect(Shift.parse((await call('get', `/api/shifts/${shift.id}`, owner)).body).id).toBe(
      shift.id,
    );
  });
});
