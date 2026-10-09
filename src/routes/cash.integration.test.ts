// K01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates a bank, gives the main safe an opening balance, transfers to the
// bank, reads both ledgers (closing = balance), moves the money back and deactivates the emptied
// bank; an accountant transfers (201) but can't create (403); a cashier gets 403 on the list.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  CashAccountList,
  CashLedger,
  CashTransfer,
  CashTransferList,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('K01 vaults against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let accountant: string;
  let cashier: string;
  let org: string;
  let mainSafe: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'patch',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.59.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.59.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'ACCOUNTANT' | 'CASHIER', branchId: string) {
    const email = `k01.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
        full_name: role,
        role,
        default_branch_id: branchId,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branchId });
    return email;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `k01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.59.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'K01 shop',
        tenant_slug: `k01-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.59.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service
      .from('branches')
      .select('id, default_cash_account_id')
      .eq('organization_id', org)
      .single();
    expect(main.error).toBeNull();
    mainSafe = main.data!.default_cash_account_id as string;
    accountant = await login(await addEmployee('ACCOUNTANT', main.data!.id));
    cashier = await login(await addEmployee('CASHIER', main.data!.id));
  }, 60_000);

  it('owner: bank, opening, transfer, ledgers, transfer back, deactivate', async () => {
    const created = await call('post', '/api/cash-accounts', owner, {
      name: ' NBE ',
      kind: 'bank',
      branch_id: null,
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const bank = CashAccount.parse(created.body);
    expect(bank).toMatchObject({
      name: 'NBE',
      branch_id: null,
      balance: '0.00',
      is_default: false,
    });
    expect(
      (
        await call('post', '/api/cash-accounts', owner, {
          name: 'NBE',
          kind: 'bank',
          branch_id: null,
        })
      ).status,
    ).toBe(409);

    const opened = await call(
      'post',
      `/api/cash-accounts/${mainSafe}/opening`,
      owner,
      { amount: '5000.00', note: 'Counted on day one' },
      `k01-open-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(200);
    expect(CashAccount.parse(opened.body).balance).toBe('5000.00');

    const key = `k01-cx-${STAMP}`;
    const moved = await call(
      'post',
      '/api/cash-transfers',
      owner,
      { from_account_id: mainSafe, to_account_id: bank.id, amount: '1200.00' },
      key,
    );
    expect(moved.status, JSON.stringify(moved.body)).toBe(201);
    const transfer = CashTransfer.parse(moved.body);
    expect(transfer.number).toContain('CX');
    const again = await call(
      'post',
      '/api/cash-transfers',
      owner,
      { from_account_id: mainSafe, to_account_id: bank.id, amount: '1200.00' },
      key,
    );
    expect(CashTransfer.parse(again.body).id).toBe(transfer.id);
    const tooMuch = await call(
      'post',
      '/api/cash-transfers',
      owner,
      { from_account_id: mainSafe, to_account_id: bank.id, amount: '9999.00' },
      `k01-cx-big-${STAMP}`,
    );
    expect(tooMuch.status).toBe(409);
    expect(code(tooMuch)).toBe('INSUFFICIENT_FUNDS');

    const safeLedger = CashLedger.parse(
      (await call('get', `/api/cash-accounts/${mainSafe}/movements`)).body,
    );
    expect(safeLedger).toMatchObject({ closing_balance: '3800.00', total: 2 });
    expect(safeLedger.account.balance).toBe('3800.00');
    expect(safeLedger.items.map((r) => [r.type, r.amount, r.balance_after])).toEqual([
      ['transfer_out', '-1200.00', '3800.00'],
      ['opening', '5000.00', '5000.00'],
    ]);
    const bankLedger = CashLedger.parse(
      (await call('get', `/api/cash-accounts/${bank.id}/movements`)).body,
    );
    expect(bankLedger).toMatchObject({ closing_balance: '1200.00', total: 1 });
    expect(bankLedger.account.balance).toBe('1200.00');
    expect(bankLedger.items[0]!.source_number).toBe(transfer.number);

    const busy = await call('post', `/api/cash-accounts/${bank.id}/deactivate`);
    expect(busy.status).toBe(409);
    expect(code(busy)).toBe('CASH_ACCOUNT_HAS_BALANCE');
    const back = await call(
      'post',
      '/api/cash-transfers',
      owner,
      { from_account_id: bank.id, to_account_id: mainSafe, amount: '1200.00', note: 'Back' },
      `k01-cx-back-${STAMP}`,
    );
    expect(back.status, JSON.stringify(back.body)).toBe(201);
    const off = await call('post', `/api/cash-accounts/${bank.id}/deactivate`);
    expect(off.status, JSON.stringify(off.body)).toBe(200);
    expect(CashAccount.parse(off.body).is_active).toBe(false);
    const isDefault = await call('post', `/api/cash-accounts/${mainSafe}/deactivate`);
    expect(code(isDefault)).toBe('CASH_ACCOUNT_HAS_BALANCE');

    const transfers = CashTransferList.parse(
      (await call('get', `/api/cash-transfers?account_id=${bank.id}`)).body,
    );
    expect(transfers.total).toBe(2);
    const inactive = CashAccountList.parse(
      (await call('get', '/api/cash-accounts?status=inactive')).body,
    );
    expect(inactive.map((a) => a.id)).toEqual([bank.id]);
  });

  it('accountant transfers but cannot create; cashier cannot list', async () => {
    const created = await call('post', '/api/cash-accounts', owner, {
      name: 'CIB',
      kind: 'bank',
      branch_id: null,
    });
    const cib = CashAccount.parse(created.body);
    const moved = await call(
      'post',
      '/api/cash-transfers',
      accountant,
      { from_account_id: mainSafe, to_account_id: cib.id, amount: '10.00' },
      `k01-acc-${STAMP}`,
    );
    expect(moved.status, JSON.stringify(moved.body)).toBe(201);
    const denied = await call('post', '/api/cash-accounts', accountant, {
      name: 'Nope',
      kind: 'bank',
      branch_id: null,
    });
    expect(denied.status).toBe(403);
    expect((await call('get', '/api/cash-accounts', accountant)).status).toBe(200);
    expect((await call('get', '/api/cash-accounts', cashier)).status).toBe(403);
    expect((await call('get', '/api/cash-transfers', cashier)).status).toBe(403);
  });
});
