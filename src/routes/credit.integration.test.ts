// R03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner sets a customer's limit and reads the profile; a cashier (sale.create, no
// credit.approve) reads it, asks for an exception, can't set a limit or decide; the owner approves
// it and the preview read shows the approved exception; a cancel and a rejection.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CreditCheck,
  CreditException,
  CreditExceptionList,
  CreditProfile,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('R03 credit profile and limit against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let collector: string;
  let org: string;
  let ip = 0;
  const nextIp = () => `198.18.73.${(++ip % 250) + 1}`;
  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token = owner,
    body?: object,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function newShop(tag: string) {
    const email = `r03.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `R03 ${tag}`,
        tenant_slug: `r03-${tag}-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', nextIp())
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    return { id: shop.body.organization_id as string, token: await login(email) };
  }
  async function addEmployee(role: 'CASHIER' | 'COLLECTOR', branchId: string) {
    const email = `r03.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
  async function newCustomer(name: string, income = '8000.00') {
    const r = await call('post', '/api/customers', owner, {
      full_name: `${name} ${STAMP}`,
      phones: ['01500000020'],
      monthly_income: income,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return (r.body as { id: string }).id;
  }
  async function ask(customerId: string, amount: string, reason: string, token = cashier) {
    const r = await call('post', `/api/customers/${customerId}/credit-exceptions`, token, {
      financed_amount: amount,
      reason,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return CreditException.parse(r.body);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = await login('superadmin@ecotech.test');
    const shop = await newShop('main');
    org = shop.id;
    owner = shop.token;
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    cashier = await login(await addEmployee('CASHIER', main.data!.id));
    collector = await login(await addEmployee('COLLECTOR', main.data!.id));
  }, 90_000);

  it('owner sets a limit and reads the profile; a cashier is refused; an exception is requested, approved and shown by the preview', async () => {
    const customerId = await newCustomer('Credit One');
    const settings = await call('patch', '/api/settings', owner, {
      credit_limit_income_multiple: '3',
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);

    const fresh = await call('get', `/api/customers/${customerId}/credit`);
    expect(fresh.status, JSON.stringify(fresh.body)).toBe(200);
    expect(CreditProfile.parse(fresh.body)).toMatchObject({
      credit_limit: '0.00',
      exposure: '0.00',
      available: '0.00',
      over_limit_by: '0.00',
      suggested_limit: '24000.00',
      status: 'active',
      limit_history: [],
    });

    // Raising needs a reason; the same body with one works.
    const noReason = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '15000.00',
    });
    expect(noReason.status).toBe(400);
    expect(code(noReason)).toBe('CREDIT_REASON_REQUIRED');
    const set = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '15000.00',
      reason: '  Good payer  ',
    });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    const profile = CreditProfile.parse(set.body);
    expect(profile).toMatchObject({ credit_limit: '15000.00', available: '15000.00' });
    expect(profile.limit_history).toHaveLength(1);
    expect(profile.limit_history[0]).toMatchObject({
      from: '0.00',
      to: '15000.00',
      reason: 'Good payer',
    });
    expect(profile.components.map((c) => c.key)).toEqual([
      'guarantors',
      'income',
      'residence',
      'identity',
    ]);

    // The cashier reads the profile (and a collector, with a read key) but can't set a limit.
    expect((await call('get', `/api/customers/${customerId}/credit`, cashier)).status).toBe(200);
    expect((await call('get', `/api/customers/${customerId}/credit`, collector)).status).toBe(200);
    const denied = await call('put', `/api/customers/${customerId}/credit-limit`, cashier, {
      credit_limit: '99000.00',
      reason: 'I want more',
    });
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const stillSame = await call('get', `/api/customers/${customerId}/credit`);
    expect(CreditProfile.parse(stillSame.body).credit_limit).toBe('15000.00');

    // 20 000 is above the limit (and the score is below the minimum): an exception is needed.
    const before = await call(
      'get',
      `/api/customers/${customerId}/credit-check?financed_amount=20000.00`,
      cashier,
    );
    expect(before.status, JSON.stringify(before.body)).toBe(200);
    expect(CreditCheck.parse(before.body)).toMatchObject({
      allowed: false,
      needs_approval: true,
      reasons: ['limit', 'score'],
      limit: '15000.00',
      available: '15000.00',
      pending_approval_id: null,
      approved_approval_id: null,
    });

    // The cashier asks; they can't decide it; the owner approves it.
    const asked = await ask(customerId, '20000.00', 'Big sofa set');
    expect(asked).toMatchObject({ status: 'pending', mine: true, reasons: ['limit', 'score'] });
    expect(asked.snapshot).toMatchObject({ limit: '15000.00', available: '15000.00' });
    const pending = await call(
      'get',
      `/api/customers/${customerId}/credit-check?financed_amount=20000.00`,
    );
    expect(CreditCheck.parse(pending.body).pending_approval_id).toBe(asked.id);
    const cashierDecide = await call('post', `/api/credit-exceptions/${asked.id}/decide`, cashier, {
      approve: true,
    });
    expect(cashierDecide.status).toBe(403);
    expect(code(cashierDecide)).toBe('PERMISSION_DENIED');
    const listed = await call('get', '/api/credit-exceptions');
    expect(listed.status, JSON.stringify(listed.body)).toBe(200);
    const items = CreditExceptionList.parse(listed.body).items;
    expect(items.map((i) => [i.id, i.mine])).toContainEqual([asked.id, false]);

    const decided = await call('post', `/api/credit-exceptions/${asked.id}/decide`, owner, {
      approve: true,
      note: 'Known customer',
    });
    expect(decided.status, JSON.stringify(decided.body)).toBe(200);
    const approved = CreditException.parse(decided.body);
    expect(approved).toMatchObject({
      status: 'approved',
      decided_by_name: 'Owner',
      decision_note: 'Known customer',
      used: false,
    });
    expect(Date.parse(approved.expires_at!) - Date.parse(approved.decided_at!)).toBe(24 * 3600_000);
    const again = await call('post', `/api/credit-exceptions/${asked.id}/decide`, owner, {
      approve: false,
      note: 'Changed my mind',
    });
    expect(again.status).toBe(409);
    expect(code(again)).toBe('APPROVAL_NOT_PENDING');

    // Done when: the preview now shows the approved exception.
    const after = await call(
      'get',
      `/api/customers/${customerId}/credit-check?financed_amount=20000.00`,
      cashier,
    );
    expect(CreditCheck.parse(after.body)).toMatchObject({
      allowed: true,
      needs_approval: false,
      approved_approval_id: asked.id,
      pending_approval_id: null,
    });
    const read = await call('get', `/api/credit-exceptions/${asked.id}`, cashier);
    expect(CreditException.parse(read.body)).toMatchObject({ status: 'approved', mine: true });
  });

  it('cancel by the requester only, reject needs a note, bad input is 400 and an amount that passes needs no exception', async () => {
    const customerId = await newCustomer('Credit Two');
    const one = await ask(customerId, '5000.00', 'Cancelled sale');
    const notYours = await call('post', `/api/credit-exceptions/${one.id}/cancel`, owner);
    expect(notYours.status).toBe(404);
    expect(code(notYours)).toBe('APPROVAL_NOT_FOUND');
    const cancelled = await call('post', `/api/credit-exceptions/${one.id}/cancel`, cashier);
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    expect(CreditException.parse(cancelled.body).status).toBe('cancelled');
    const cancelAgain = await call('post', `/api/credit-exceptions/${one.id}/cancel`, cashier);
    expect(cancelAgain.status).toBe(409);
    expect(code(cancelAgain)).toBe('APPROVAL_NOT_PENDING');

    const two = await ask(customerId, '6000.00', 'Rejected sale');
    const noNote = await call('post', `/api/credit-exceptions/${two.id}/decide`, owner, {
      approve: false,
    });
    expect(noNote.status).toBe(400);
    expect(code(noNote)).toBe('APPROVAL_NOTE_REQUIRED');
    const rejected = await call('post', `/api/credit-exceptions/${two.id}/decide`, owner, {
      approve: false,
      note: 'Too much for this customer',
    });
    expect(CreditException.parse(rejected.body)).toMatchObject({
      status: 'rejected',
      decision_note: 'Too much for this customer',
      expires_at: null,
    });

    const byStatus = await call('get', '/api/credit-exceptions?status=all');
    expect(CreditExceptionList.parse(byStatus.body).items.length).toBeGreaterThanOrEqual(2);
    const onlyRejected = await call('get', '/api/credit-exceptions?status=rejected');
    expect(
      CreditExceptionList.parse(onlyRejected.body).items.every((i) => i.status === 'rejected'),
    ).toBe(true);

    // A bad request never reaches the data.
    const unknownKey = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '1000.00',
      organization_id: org,
    });
    expect(unknownKey.status).toBe(400);
    const negative = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '-1',
      reason: 'No',
    });
    expect(negative.status).toBe(400);
    const noAmount = await call('get', `/api/customers/${customerId}/credit-check`, cashier);
    expect(noAmount.status).toBe(400);
    const badStatus = await call('get', '/api/credit-exceptions?status=expired');
    expect(badStatus.status).toBe(400);
    const notAUuid = await call('get', '/api/credit-exceptions/not-a-uuid');
    expect(notAUuid.status).toBe(400);
  });
});
