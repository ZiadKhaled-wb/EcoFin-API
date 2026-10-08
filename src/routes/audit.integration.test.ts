// F07 against local Supabase: every write route in the audit registry that has an action writes
// exactly ONE audit_log row with that action, this request's id and the client IP; and the
// search endpoint. Skipped unless RUN_INTEGRATION=1 (env: see src/routes/auth.integration.test.ts).
// Throwaway employees (unique per run) are used where a route changes someone's data.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuditSearchResponse, AuthLoginResponse, ErrorResponse } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { AUDIT_REGISTRY } from '../test/audit-registry/registry';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SEED_PASSWORD = 'LocalDev-Only-2026!';
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const SHOP_TWO = 'd1000000-0000-0000-0000-000000000002';
const BR1 = 'd2000000-0000-0000-0000-000000000011';
const OWNER_ONE = 'd3000000-0000-0000-0000-000000000011';
const STAMP = Date.now();
const TEMP_PASSWORD = `F07-${STAMP}!`;
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]);

// 198.18.2.0/24; the other integration files use other ranges.
let ipCounter = 0;
const nextIp = () => `198.18.2.${(ipCounter++ % 250) + 1}`;

interface Sent {
  res: request.Response;
  ip: string;
  requestId: string;
}

describe.skipIf(!RUN)('F07 audit against local Supabase', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let targetId: string;
  let pwEmail: string;
  let pwAuthId: string;

  /** One request with its own IP and request id, so its audit row can be found exactly. */
  async function send(
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    opts: { token?: string; orgId?: string; body?: object; key?: string } = {},
  ): Promise<Sent> {
    const ip = nextIp();
    const requestId = `f07-${STAMP}-${ipCounter}`;
    let r = request(app)[method](path).set('X-Forwarded-For', ip).set('x-request-id', requestId);
    if (opts.token) r = r.set('Authorization', `Bearer ${opts.token}`);
    if (opts.orgId) r = r.set('x-org-id', opts.orgId);
    if (opts.key) r = r.set('Idempotency-Key', opts.key);
    const res = opts.body ? await r.send(opts.body) : await r;
    return { res, ip, requestId };
  }
  async function login(identifier: string, password = SEED_PASSWORD) {
    const { res } = await send('post', '/api/auth/login', { body: { identifier, password } });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body);
  }
  async function rowsFor(requestId: string) {
    const { data, error } = await service
      .from('audit_log')
      .select('action, ip, request_id, organization_id, employee_id')
      .eq('request_id', requestId);
    if (error) throw new Error(error.message);
    return data as {
      action: string;
      ip: string;
      request_id: string;
      organization_id: string;
      employee_id: string | null;
    }[];
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const taxClassBody = () => ({
    name: `F07 ${STAMP}-${ipCounter}`,
    kind: 'standard',
    rate: '5',
    eta_tax_type: 'T1',
    eta_subtype: 'V010',
  });
  async function newTaxClass(token: string) {
    const { res } = await send('post', '/api/tax-classes', { token, body: taxClassBody() });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return (res.body as { id: string }).id;
  }
  const categoryBody = () => ({ name: `F07 ${STAMP}-${ipCounter}` });
  async function newCategory(token: string) {
    const { res } = await send('post', '/api/categories', { token, body: categoryBody() });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return (res.body as { id: string }).id;
  }
  const productBody = () => ({
    name_ar: `F07 ${STAMP}-${ipCounter}`,
    sku: `F07-${STAMP}-${ipCounter}`,
    cash_price: '10.00',
  });
  /** An open count of a new, empty category in BR1 (the request itself is returned). */
  async function newCount(token: string) {
    const category = await newCategory(token);
    const sent = await send('post', '/api/stock/counts', {
      token,
      key: `f07-count-${STAMP}-${ipCounter}`,
      body: { branch_id: BR1, category_id: category },
    });
    expect(sent.res.status, JSON.stringify(sent.res.body)).toBe(201);
    return sent;
  }
  async function newProduct(token: string) {
    const { res } = await send('post', '/api/products', { token, body: productBody() });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return (res.body as { id: string }).id;
  }

  async function createEmployee(email: string, password: string) {
    const user = await service.auth.admin.createUser({ email, password, email_confirm: true });
    if (user.error) throw new Error(user.error.message);
    const emp = await service
      .from('employees')
      .insert({
        organization_id: SHOP_ONE,
        auth_user_id: user.data.user.id,
        full_name: `F07 ${email.split('@')[0]}`,
        email,
        username: email.split('@')[0],
        role: 'CASHIER',
        default_branch_id: BR1,
      })
      .select('id')
      .single();
    if (emp.error) throw new Error(emp.error.message);
    return { id: emp.data.id as string, authId: user.data.user.id };
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    targetId = (await createEmployee(`f07.target.${STAMP}@ecotech.test`, TEMP_PASSWORD)).id;
    pwEmail = `f07.pw.${STAMP}@ecotech.test`;
    pwAuthId = (await createEmployee(pwEmail, TEMP_PASSWORD)).authId;
  });

  afterAll(async () => {
    await service
      .from('employees')
      .update({ is_active: false, archived_at: new Date().toISOString() })
      .in('email', [`f07.target.${STAMP}@ecotech.test`, pwEmail]);
  });

  // One driver per registry entry that has an action: performs the call, returns what was sent,
  // the shop the row must land in and the success status (200 unless the route creates: 201).
  const drivers: Record<string, () => Promise<{ sent: Sent; org: string; status?: number }>> = {
    'POST /api/employees': () => staffAudit('create'),
    'PATCH /api/employees/:employeeId': () => staffAudit('update'),
    'PUT /api/employees/:employeeId/active': () => staffAudit('active'),
    'POST /api/employees/:employeeId/invite': () => staffAudit('invite'),
    'POST /api/employees/:employeeId/password-reset': () => staffAudit('reset'),
    'POST /api/auth/password-reset/complete': () => staffAudit('complete'),
    'POST /api/tax-classes': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('post', '/api/tax-classes', {
          token: owner.accessToken,
          body: taxClassBody(),
        }),
        org: SHOP_ONE,
        status: 201,
      };
    },
    'PATCH /api/tax-classes/:id': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newTaxClass(owner.accessToken);
      return {
        sent: await send('patch', `/api/tax-classes/${id}`, {
          token: owner.accessToken,
          body: { rate: '6' },
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/tax-classes/:id/archive': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newTaxClass(owner.accessToken);
      return {
        sent: await send('post', `/api/tax-classes/${id}/archive`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/tax-classes/:id/restore': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newTaxClass(owner.accessToken);
      expect(
        (await send('post', `/api/tax-classes/${id}/archive`, { token: owner.accessToken })).res
          .status,
      ).toBe(200);
      return {
        sent: await send('post', `/api/tax-classes/${id}/restore`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/categories': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('post', '/api/categories', {
          token: owner.accessToken,
          body: categoryBody(),
        }),
        org: SHOP_ONE,
        status: 201,
      };
    },
    'PATCH /api/categories/:id': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newCategory(owner.accessToken);
      return {
        sent: await send('patch', `/api/categories/${id}`, {
          token: owner.accessToken,
          body: categoryBody(),
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/categories/:id/archive': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newCategory(owner.accessToken);
      return {
        sent: await send('post', `/api/categories/${id}/archive`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/categories/:id/restore': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newCategory(owner.accessToken);
      expect(
        (await send('post', `/api/categories/${id}/archive`, { token: owner.accessToken })).res
          .status,
      ).toBe(200);
      return {
        sent: await send('post', `/api/categories/${id}/restore`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/products': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('post', '/api/products', {
          token: owner.accessToken,
          body: productBody(),
        }),
        org: SHOP_ONE,
        status: 201,
      };
    },
    // A non-price change: product.updated (product.price_changed is proven in SQL and in
    // products.integration.test.ts).
    'PATCH /api/products/:id': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newProduct(owner.accessToken);
      return {
        sent: await send('patch', `/api/products/${id}`, {
          token: owner.accessToken,
          body: { name_en: `F07 ${STAMP}-${ipCounter}` },
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/products/:id/archive': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newProduct(owner.accessToken);
      return {
        sent: await send('post', `/api/products/${id}/archive`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/products/:id/restore': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newProduct(owner.accessToken);
      expect(
        (await send('post', `/api/products/${id}/archive`, { token: owner.accessToken })).res
          .status,
      ).toBe(200);
      return {
        sent: await send('post', `/api/products/${id}/restore`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/stock/adjustments': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = await newProduct(owner.accessToken);
      return {
        sent: await send('post', '/api/stock/adjustments', {
          token: owner.accessToken,
          key: `f07-adj-${STAMP}-${ipCounter}`,
          body: { branch_id: BR1, reason: 'found', lines: [{ product_id: id, quantity: 1 }] },
        }),
        org: SHOP_ONE,
        status: 201,
      };
    },
    // Counts use a fresh (empty) category each, so they never overlap an open count of the branch.
    'POST /api/stock/counts': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await newCount(owner.accessToken),
        org: SHOP_ONE,
        status: 201,
      };
    },
    'POST /api/stock/counts/:id/post': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = (await newCount(owner.accessToken)).res.body.id as string;
      return {
        sent: await send('post', `/api/stock/counts/${id}/post`, {
          token: owner.accessToken,
          key: `f07-post-${STAMP}-${ipCounter}`,
          body: {},
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/stock/counts/:id/cancel': async () => {
      const owner = await login('owner.one@ecotech.test');
      const id = (await newCount(owner.accessToken)).res.body.id as string;
      return {
        sent: await send('post', `/api/stock/counts/${id}/cancel`, { token: owner.accessToken }),
        org: SHOP_ONE,
      };
    },
    'PATCH /api/settings': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('patch', '/api/settings', {
          token: owner.accessToken,
          body: { receipt_footer: `F07 ${STAMP}-${ipCounter}` },
        }),
        org: SHOP_ONE,
      };
    },
    'PATCH /api/settings/profile': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('patch', '/api/settings/profile', {
          token: owner.accessToken,
          body: { consumer_finance_legal_status: `FRA note ${STAMP}-${ipCounter}` },
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/settings/installment-policies': async () => {
      const owner = await login('owner.one@ecotech.test');
      const current = await send('get', '/api/settings', { token: owner.accessToken });
      const grace =
        (((current.res.body as { installment_policy: { grace_days: number } | null })
          .installment_policy?.grace_days ?? 0) +
          1) %
        366;
      return {
        sent: await send('post', '/api/settings/installment-policies', {
          token: owner.accessToken,
          body: { grace_days: grace },
        }),
        org: SHOP_ONE,
        status: 201,
      };
    },
    'POST /api/branches': async () => {
      const f = await branchShop('create');
      return {
        sent: await send('post', '/api/branches', {
          token: f.owner,
          orgId: f.org,
          body: { name: 'Audit branch', code: 'B2' },
        }),
        org: f.org,
        status: 201,
      };
    },
    'PATCH /api/branches/:id': async () => {
      const f = await branchShop('update');
      return {
        sent: await send('patch', `/api/branches/${f.branch}`, {
          token: f.owner,
          orgId: f.org,
          body: { name: 'Updated' },
        }),
        org: f.org,
      };
    },
    'POST /api/branches/:id/deactivate': async () => {
      const f = await branchShop('deactivate');
      return {
        sent: await send('post', `/api/branches/${f.branch}/deactivate`, {
          token: f.owner,
          orgId: f.org,
          body: { reason: 'Audit' },
        }),
        org: f.org,
      };
    },
    'POST /api/branches/:id/reactivate': async () => {
      const f = await branchShop('reactivate');
      expect(
        (
          await send('post', `/api/branches/${f.branch}/deactivate`, {
            token: f.owner,
            orgId: f.org,
            body: { reason: 'Setup' },
          })
        ).res.status,
      ).toBe(200);
      return {
        sent: await send('post', `/api/branches/${f.branch}/reactivate`, {
          token: f.owner,
          orgId: f.org,
        }),
        org: f.org,
      };
    },
    'POST /api/admin/shops/:id/plan': async () => {
      const f = await platformShop('plan');
      return {
        sent: await send('post', `/api/admin/shops/${f.org}/plan`, {
          token: f.admin,
          body: { plan_key: 'retail', reason: 'audit' },
        }),
        org: f.org,
      };
    },
    'POST /api/admin/shops/:id/subscription-dates': async () => {
      const f = await platformShop('dates');
      return {
        sent: await send('post', `/api/admin/shops/${f.org}/subscription-dates`, {
          token: f.admin,
          body: { start: '2026-10-01', end: '2027-10-01', reason: 'audit' },
        }),
        org: f.org,
      };
    },
    'POST /api/admin/shops/:id/payments': async () => {
      const f = await platformShop('payment');
      return {
        sent: await send('post', `/api/admin/shops/${f.org}/payments`, {
          token: f.admin,
          key: 'a0500000-0000-4000-8000-000000000003',
          body: { amount: '500.25', period_start: '2026-10-01', period_end: '2027-10-01' },
        }),
        org: f.org,
        status: 201,
      };
    },
    'POST /api/admin/shops': async () => {
      const fixture = await platformShop('create');
      return { sent: fixture.sent, org: fixture.org, status: 201 };
    },
    'POST /api/admin/shops/:id/status': async () => {
      const fixture = await platformShop('status');
      return {
        sent: await send('post', `/api/admin/shops/${fixture.org}/status`, {
          token: fixture.admin,
          body: { status: 'suspended', reason: 'audit test' },
        }),
        org: fixture.org,
      };
    },
    'POST /api/admin/shops/:id/owner-invite': async () => {
      const fixture = await platformShop('resend');
      return {
        sent: await send('post', `/api/admin/shops/${fixture.org}/owner-invite`, {
          token: fixture.admin,
        }),
        org: fixture.org,
      };
    },
    'POST /api/auth/invites/accept': async () => {
      const fixture = await platformShop('accept');
      const token = await readInviteToken(fixture.email);
      return {
        sent: await send('post', '/api/auth/invites/accept', {
          body: { token, password: TEMP_PASSWORD },
        }),
        org: fixture.org,
      };
    },
    'POST /api/auth/login': async () => ({
      sent: await send('post', '/api/auth/login', {
        body: { identifier: 'owner.one@ecotech.test', password: SEED_PASSWORD },
      }),
      org: SHOP_ONE,
    }),
    'POST /api/auth/select-shop': async () => {
      const multi = await login('multi.shop@ecotech.test');
      return {
        sent: await send('post', '/api/auth/select-shop', {
          token: multi.accessToken,
          body: { orgId: SHOP_TWO },
        }),
        org: SHOP_TWO,
      };
    },
    'POST /api/auth/logout': async () => {
      const s = await login('owner.one@ecotech.test');
      return {
        sent: await send('post', '/api/auth/logout', { token: s.accessToken }),
        org: SHOP_ONE,
      };
    },
    'POST /api/auth/change-password': async () => {
      const s = await login(pwEmail, TEMP_PASSWORD);
      const sent = await send('post', '/api/auth/change-password', {
        token: s.accessToken,
        body: { currentPassword: TEMP_PASSWORD, newPassword: `${TEMP_PASSWORD}-new` },
      });
      // Put the password back for reruns of this driver.
      await service.auth.admin.updateUserById(pwAuthId, { password: TEMP_PASSWORD });
      return { sent, org: SHOP_ONE };
    },
    'PUT /api/employees/:employeeId/permissions': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('put', `/api/employees/${targetId}/permissions`, {
          token: owner.accessToken,
          body: { permissionKey: 'sale.void', granted: true, reason: 'audit test' },
        }),
        org: SHOP_ONE,
      };
    },
    'PUT /api/employees/:employeeId/branches': async () => {
      const owner = await login('owner.one@ecotech.test');
      return {
        sent: await send('put', `/api/employees/${targetId}/branches`, {
          token: owner.accessToken,
          body: { branchIds: [BR1], reason: 'audit test' },
        }),
        org: SHOP_ONE,
      };
    },
    'POST /api/files': async () => {
      const owner = await login('owner.one@ecotech.test');
      // Multipart, so not through send(): same headers, one small PNG as a shop logo.
      const ip = nextIp();
      const requestId = `f07-${STAMP}-${ipCounter}`;
      const res = await request(app)
        .post('/api/files')
        .set('X-Forwarded-For', ip)
        .set('x-request-id', requestId)
        .set('Authorization', `Bearer ${owner.accessToken}`)
        .field('purpose', 'logo')
        .attach('file', PNG, 'logo.png');
      return { sent: { res, ip, requestId }, org: SHOP_ONE, status: 201 };
    },
  };

  async function staffAudit(action: string) {
    const f = await platformShop('staff-' + action);
    const accepted = await send('post', '/api/auth/invites/accept', {
      body: { token: await readInviteToken(f.email), password: SEED_PASSWORD },
    });
    expect(accepted.res.status).toBe(200);
    const owner = (await login(f.email)).accessToken;
    const branches = await send('get', '/api/branches', { token: owner, orgId: f.org });
    expect(branches.res.status).toBe(200);
    const opts = { token: owner, orgId: f.org };
    const made = await send('post', '/api/employees', {
      ...opts,
      body: {
        full_name: 'Audit staff',
        username: 'audit.' + action,
        role: 'CASHIER',
        branch_ids: [branches.res.body[0].id],
      },
    });
    if (action === 'create') return { sent: made, org: f.org, status: 201 };
    expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
    const id = made.res.body.employee_id as string;
    if (action === 'update')
      return {
        sent: await send('patch', `/api/employees/${id}`, {
          ...opts,
          body: { full_name: 'Edited' },
        }),
        org: f.org,
      };
    if (action === 'active')
      return {
        sent: await send('put', `/api/employees/${id}/active`, {
          ...opts,
          body: { active: false, reason: 'Disabled' },
        }),
        org: f.org,
      };
    if (action === 'invite')
      return { sent: await send('post', `/api/employees/${id}/invite`, opts), org: f.org };
    expect(
      (
        await send('post', '/api/auth/invites/accept', {
          body: {
            token: new URL(made.res.body.invite_link).hash.slice(7),
            password: SEED_PASSWORD,
          },
        })
      ).res.status,
    ).toBe(200);
    const reset = await send('post', `/api/employees/${id}/password-reset`, opts);
    if (action === 'reset') return { sent: reset, org: f.org };
    expect(reset.res.status).toBe(200);
    return {
      sent: await send('post', '/api/auth/password-reset/complete', {
        body: {
          token: new URL(reset.res.body.reset_link).hash.slice(7),
          password: 'Reset-Audit-2026!',
        },
      }),
      org: f.org,
    };
  }
  async function platformShop(suffix: string) {
    const admin = (await login('superadmin@ecotech.test')).accessToken;
    const email = `f07.p01.${suffix}.${STAMP}@ecotech.test`;
    const sent = await send('post', '/api/admin/shops', {
      token: admin,
      body: {
        name: `F07 ${suffix}`,
        tenant_slug: `f07-${STAMP}-${suffix}`,
        plan_key: 'starter',
        owner: { full_name: 'Audit owner', email },
      },
    });
    expect(sent.res.status, JSON.stringify(sent.res.body)).toBe(201);
    const org = sent.res.body.organization_id as string;
    return { sent, org, email, admin };
  }
  async function branchShop(suffix: string) {
    const f = await platformShop('branch-' + suffix);
    expect(
      (
        await send('post', `/api/admin/shops/${f.org}/plan`, {
          token: f.admin,
          body: { plan_key: 'retail', reason: 'Branch fixture' },
        })
      ).res.status,
    ).toBe(200);
    expect(
      (
        await send('post', '/api/auth/invites/accept', {
          body: { token: await readInviteToken(f.email), password: SEED_PASSWORD },
        })
      ).res.status,
    ).toBe(200);
    const owner = (await login(f.email)).accessToken;
    let branch = '';
    if (suffix !== 'create') {
      const made = await send('post', '/api/branches', {
        token: owner,
        orgId: f.org,
        body: { name: 'Branch', code: 'B2' },
      });
      expect(made.res.status).toBe(201);
      branch = made.res.body.id as string;
    }
    return { ...f, owner, branch };
  }

  const withAction = Object.entries(AUDIT_REGISTRY).flatMap(([route, e]) =>
    'action' in e ? [{ route, action: e.action }] : [],
  );

  it('every registry entry with an action has a driver here', () => {
    expect(withAction.map((w) => w.route).sort()).toEqual(Object.keys(drivers).sort());
  });

  it.each(withAction)(
    '$route writes exactly one $action row with the request id and IP',
    async ({ route, action }) => {
      const driver = drivers[route];
      if (!driver) throw new Error(`no driver for ${route}`);
      const { sent, org, status = 200 } = await driver();
      expect(sent.res.status, JSON.stringify(sent.res.body)).toBe(status);
      expect(sent.res.headers['x-request-id']).toBe(sent.requestId);
      const rows = await rowsFor(sent.requestId);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        action,
        ip: sent.ip,
        request_id: sent.requestId,
        organization_id: org,
      });
    },
  );

  it('routes registered as none write no audit row', async () => {
    const refresh = await send('post', '/api/auth/refresh', { body: { refreshToken: 'nope' } });
    expect(refresh.res.status).toBe(401);
    const forgot = await send('post', '/api/auth/forgot-password', {
      body: { identifier: `nobody.${STAMP}@ecotech.test` },
    });
    expect(forgot.res.status).toBe(202);
    expect(await rowsFor(refresh.requestId)).toHaveLength(0);
    expect(await rowsFor(forgot.requestId)).toHaveLength(0);
  });

  describe('GET /api/audit', () => {
    it('the owner finds their own login: newest first, with the actor name, request id and IP', async () => {
      const { sent } = await drivers['POST /api/auth/login']!();
      const owner = AuthLoginResponse.parse(sent.res.body);
      const { res } = await send('get', '/api/audit', {
        token: owner.accessToken,
        orgId: SHOP_ONE,
      });
      expect(res.status, JSON.stringify(res.body)).toBe(200);
      const all = AuditSearchResponse.parse(res.body);
      const times = all.items.map((r) => Date.parse(r.createdAt));
      expect([...times].sort((a, b) => b - a)).toEqual(times);

      const filtered = await request(app)
        .get('/api/audit')
        .query({ action: 'auth.login', actorEmployeeId: OWNER_ONE, pageSize: 100 })
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${owner.accessToken}`);
      expect(filtered.status).toBe(200);
      const page = AuditSearchResponse.parse(filtered.body);
      const row = page.items.find((r) => r.requestId === sent.requestId);
      expect(row).toMatchObject({
        action: 'auth.login',
        employeeId: OWNER_ONE,
        actorName: 'Owner One',
        ip: sent.ip,
      });
      expect(page.items.every((r) => r.action === 'auth.login' && r.employeeId === OWNER_ONE)).toBe(
        true,
      );
    });

    it('pagination: page 2 continues page 1; a page past the end is empty with the real total', async () => {
      const owner = await login('owner.one@ecotech.test');
      const get = (query: Record<string, string | number>) =>
        request(app)
          .get('/api/audit')
          .query(query)
          .set('X-Forwarded-For', nextIp())
          .set('Authorization', `Bearer ${owner.accessToken}`);
      // Other test files log in as this owner in parallel; a fixed upper bound keeps their
      // new auth.login rows from shifting the pages between requests.
      const to = new Date().toISOString();
      const two = AuditSearchResponse.parse(
        (await get({ pageSize: 2, action: 'auth.login', to })).body,
      );
      expect(two.items).toHaveLength(2);
      const p2 = AuditSearchResponse.parse(
        (await get({ pageSize: 1, page: 2, action: 'auth.login', to })).body,
      );
      expect(p2.items[0]?.id).toBe(two.items[1]?.id);
      const past = await get({ pageSize: 100, page: 10_000, action: 'auth.login', to });
      expect(past.status).toBe(200);
      const pastBody = AuditSearchResponse.parse(past.body);
      expect(pastBody.items).toEqual([]);
      expect(pastBody.total).toBeGreaterThan(0);
    });

    it('a cashier (no audit.view) gets 403; bad filters 400', async () => {
      const cashier = await login('cashier.one@ecotech.test');
      const denied = await send('get', '/api/audit', { token: cashier.accessToken });
      expect(denied.res.status).toBe(403);
      expect(code(denied.res)).toBe('PERMISSION_DENIED');

      const owner = await login('owner.one@ecotech.test');
      for (const query of [
        { pageSize: 500 },
        { entityId: 'nope' },
        { from: '2026-10-05T00:00:00Z', to: '2026-10-01T00:00:00Z' },
        { sort: 'id' },
      ]) {
        const res = await request(app)
          .get('/api/audit')
          .query(query)
          .set('X-Forwarded-For', nextIp())
          .set('Authorization', `Bearer ${owner.accessToken}`);
        expect(res.status, JSON.stringify(query)).toBe(400);
        expect(code(res)).toBe('VALIDATION_FAILED');
      }
    });
  });
});
