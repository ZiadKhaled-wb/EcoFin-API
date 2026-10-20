// K04 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh
// shop's day over HTTP. The owner funds the safe and spends from it; a manager's open shift blocks
// the close; the shift closes; the preview's numbers equal the day's documents; something posted
// after the preview makes the close DAY_CHANGED; the close stores the snapshot and from then on an
// expense that day is DAY_CLOSED; a manager can't reopen, the owner can; the day closes again with
// the late expense. (Every rule and edge: supabase/tests/k04_day_close_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  DayClose,
  DayCloseAlerts,
  DayCloseBlockedDetail,
  DayCloseListResponse,
  DayClosePreview,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('K04 day close against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let manager: string;
  let org: string;
  let branch: string;
  let safeId: string;
  let rent: string;
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
      .set('X-Forwarded-For', `198.18.84.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `k04-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.84.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function today() {
    const { data, error } = await service
      .from('organizations')
      .select('timezone')
      .eq('id', org)
      .single();
    expect(error).toBeNull();
    return new Intl.DateTimeFormat('en-CA', { timeZone: data!.timezone as string }).format(
      new Date(),
    );
  }
  const expense = (amount: string, tag: string) =>
    call(
      'post',
      '/api/expenses',
      owner,
      { category_id: rent, amount, branch_id: branch, cash_account_id: safeId, note: tag },
      key(tag),
    );
  const preview = async (date: string) =>
    call('get', `/api/day-closes/preview?branch_id=${branch}&date=${date}`, manager);

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `k04.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.84.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'K04 shop',
        tenant_slug: `k04-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.84.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const safe = await service
      .from('cash_accounts')
      .select('id')
      .eq('organization_id', org)
      .eq('kind', 'safe')
      .single();
    expect(safe.error).toBeNull();
    safeId = safe.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    // A branch manager of the main branch (day.close by role, not day.reopen).
    const managerEmail = `k04.manager.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: managerEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: managerEmail,
        full_name: 'K04 Manager',
        role: 'BRANCH_MANAGER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    manager = await login(managerEmail);
    const funded = await call(
      'post',
      `/api/cash-accounts/${safeId}/opening`,
      owner,
      { amount: '5000.00', note: 'K04 opening' },
      key('opening'),
    );
    expect(funded.status, JSON.stringify(funded.body)).toBe(200);
    const category = await call('post', '/api/expense-categories', owner, { name: 'Rent' });
    expect(category.status, JSON.stringify(category.body)).toBe(201);
    rent = (category.body as { id: string }).id;
  });

  it('previews, refuses an open shift, closes, refuses the closed day, reopens and closes again', async () => {
    const date = await today();
    expect((await expense('150.00', 'e1')).status).toBe(201);

    // A manager's shift is open: the preview says so and the close is blocked.
    const opened = await call(
      'post',
      '/api/shifts',
      manager,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const shiftId = (opened.body as { id: string }).id;
    const blocked = DayClosePreview.parse((await preview(date)).body);
    expect(blocked.issues.some((i) => i.code === 'SHIFT_OPEN' && i.link?.id === shiftId)).toBe(
      true,
    );
    const refused = await call('post', '/api/day-closes', manager, {
      branch_id: branch,
      business_date: date,
      preview_hash: blocked.hash,
      note: 'Closing',
    });
    expect(refused.status).toBe(409);
    expect(code(refused)).toBe('DAY_CLOSE_BLOCKED');
    expect(
      DayCloseBlockedDetail.parse(ErrorResponse.parse(refused.body).error.details).issues[0]?.code,
    ).toBe('SHIFT_OPEN');
    const shiftClosed = await call('post', `/api/shifts/${shiftId}/close`, manager, {
      counts: { '1': 0 },
    });
    expect(shiftClosed.status, JSON.stringify(shiftClosed.body)).toBe(200);

    // The numbers equal the day's documents.
    const p = DayClosePreview.parse((await preview(date)).body);
    expect(p.status).toBe('open');
    expect(p.is_today).toBe(true);
    expect(p.totals.expenses.total).toBe('150.00');
    const safeRow = p.totals.cash.accounts.find((a) => a.account.id === safeId);
    expect(safeRow).toMatchObject({ opening: '0.00', in: '5000.00', out: '150.00' });
    expect(safeRow?.closing).toBe('4850.00');
    expect(p.issues.some((i) => i.severity === 'blocking')).toBe(false);

    // Posted after the preview: the close is DAY_CHANGED.
    expect((await expense('10.00', 'e2')).status).toBe(201);
    const stale = await call('post', '/api/day-closes', manager, {
      branch_id: branch,
      business_date: date,
      preview_hash: p.hash,
      note: 'Closing',
    });
    expect(stale.status).toBe(409);
    expect(code(stale)).toBe('DAY_CHANGED');

    const fresh = DayClosePreview.parse((await preview(date)).body);
    const closed = await call('post', '/api/day-closes', manager, {
      branch_id: branch,
      business_date: date,
      preview_hash: fresh.hash,
      note: 'End of day',
    });
    expect(closed.status, JSON.stringify(closed.body)).toBe(201);
    const dc = DayClose.parse(closed.body);
    expect(dc.status).toBe('closed');
    expect(dc.totals).toEqual(fresh.totals);
    expect(dc.note).toBe('End of day');

    // The closed day refuses new entries; the preview points to the stored close.
    const late = await expense('20.00', 'e3');
    expect(late.status).toBe(409);
    expect(code(late)).toBe('DAY_CLOSED');
    const again = await preview(date);
    expect(again.status).toBe(409);
    expect(code(again)).toBe('DAY_ALREADY_CLOSED');
    expect(ErrorResponse.parse(again.body).error.details).toEqual({ id: dc.id });
    const got = DayClose.parse((await call('get', `/api/day-closes/${dc.id}`, manager)).body);
    expect(got.drift).toBe(false);
    const list = DayCloseListResponse.parse(
      (await call('get', `/api/day-closes?branch_id=${branch}`, manager)).body,
    );
    expect(list.items.find((i) => i.business_date === date)).toMatchObject({
      status: 'closed',
      id: dc.id,
    });
    DayCloseAlerts.parse((await call('get', '/api/day-closes/alerts', manager)).body);

    // Reopen: not the manager; the owner with a reason. Then the late expense and a new close.
    const denied = await call('post', `/api/day-closes/${dc.id}/reopen`, manager, {
      reason: 'Late receipt',
    });
    expect(denied.status).toBe(403);
    const reopened = await call('post', `/api/day-closes/${dc.id}/reopen`, owner, {
      reason: 'Late receipt',
    });
    expect(reopened.status, JSON.stringify(reopened.body)).toBe(200);
    expect(DayClose.parse(reopened.body).status).toBe('reopened');
    expect((await expense('20.00', 'e4')).status).toBe(201);
    const re = DayClosePreview.parse((await preview(date)).body);
    expect(re.status).toBe('reopened');
    expect(re.last_close?.id).toBe(dc.id);
    expect(re.totals.expenses.total).toBe('180.00');
    const closedAgain = await call('post', '/api/day-closes', owner, {
      branch_id: branch,
      business_date: date,
      preview_hash: re.hash,
      note: 'Closed again',
    });
    expect(closedAgain.status, JSON.stringify(closedAgain.body)).toBe(201);
    expect(DayClose.parse(closedAgain.body)).toMatchObject({ id: dc.id, status: 'closed' });
  });

  it('validates the requests', async () => {
    const date = await today();
    const bad = await call('post', '/api/day-closes', manager, {
      branch_id: branch,
      business_date: date,
      preview_hash: 'nope',
    });
    expect(bad.status).toBe(400);
    const tomorrow = new Date(`${date}T00:00:00Z`);
    tomorrow.setUTCDate(tomorrow.getUTCDate() + 1);
    const future = await preview(tomorrow.toISOString().slice(0, 10));
    expect(future.status).toBe(422);
    expect(code(future)).toBe('FUTURE_BUSINESS_DATE');
    const shortReason = await call(
      'post',
      `/api/day-closes/00000000-0000-4000-8000-0000000004c4/reopen`,
      owner,
      { reason: 'ab' },
    );
    expect(shortReason.status).toBe(400);
  });
});
