import { createHash } from 'node:crypto';
import { beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AdminCreateShopResponse,
  AdminShopsResponse,
  AuthLoginResponse,
  InviteLookupResponse,
  InviteAcceptResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
let ip = 1;
describe.skipIf(!RUN)('P01 platform provisioning and invitations', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let shop: string;
  let token: string;
  const email = `p01.owner.${STAMP}@ecotech.test`;
  const call = (
    method: 'get' | 'post',
    path: string,
    body: object = {},
    access?: string,
    org?: string,
  ) => {
    let req = request(app)[method](path).set('X-Forwarded-For', `198.18.7.${ip++}`);
    if (access) req = req.set('Authorization', `Bearer ${access}`);
    if (org) req = req.set('x-org-id', org);
    return method === 'post' ? req.send(body) : req;
  };
  async function login(identifier: string, password = PASSWORD) {
    const res = await call('post', '/api/auth/login', { identifier, password });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body);
  }
  async function provision(ownerEmail: string, suffix: string) {
    const res = await call(
      'post',
      '/api/admin/shops',
      {
        name: `P01 ${suffix}`,
        tenant_slug: `p01-${STAMP}-${suffix}`,
        plan_key: 'starter',
        owner: { full_name: 'P01 Owner', email: ownerEmail },
      },
      admin,
      'ignored-invalid-shop',
    );
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const result = AdminCreateShopResponse.parse(res.body);
    expect(result.invite_email_sent).toBe(true);
    return result;
  }
  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const session = await login('superadmin@ecotech.test');
    expect(session.is_super_admin).toBe(true);
    expect(session.requiresShopSelection).toBe(false);
    admin = session.accessToken;
  });
  it('creates a usable shop through the email, invitation, login and owner endpoint flow', async () => {
    const created = await provision(email, 'main');
    shop = created.organization_id;
    token = await readInviteToken(email);
    expect(JSON.stringify(created)).not.toContain(token);
    const lookup = await call('post', '/api/auth/invites/lookup', { token });
    expect(lookup.status).toBe(200);
    expect(InviteLookupResponse.parse(lookup.body).account_exists).toBe(false);
    const accepted = await call('post', '/api/auth/invites/accept', { token, password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    expect(InviteAcceptResponse.parse(accepted.body).email).toBe(email);
    owner = (await login(email)).accessToken;
    expect((await call('get', '/api/auth/me', {}, owner, shop)).status).toBe(200);
    expect((await call('get', '/api/me/permissions', {}, owner, shop)).status).toBe(200);
    const audit = await service
      .from('audit_log')
      .select('organization_id,super_admin_id')
      .eq('entity_id', shop)
      .eq('action', 'org.provisioned');
    expect(audit.error).toBeNull();
    expect(audit.data).toHaveLength(1);
    expect(audit.data?.[0]).toMatchObject({
      organization_id: shop,
      super_admin_id: 'f0000000-0000-0000-0000-000000000001',
    });
  });
  it('rejects the used token for both lookup and acceptance', async () => {
    for (const path of ['lookup', 'accept']) {
      const res = await call('post', `/api/auth/invites/${path}`, {
        token,
        ...(path === 'accept' ? { password: PASSWORD } : {}),
      });
      expect(res.status).toBe(410);
      expect(res.body.error.code).toBe('INVITE_USED');
    }
  });
  it('rejects an expired token without creating an account', async () => {
    const expiredEmail = `p01.expired.${STAMP}@ecotech.test`;
    await provision(expiredEmail, 'expired');
    const expiredToken = await readInviteToken(expiredEmail);
    const changed = await service
      .from('invites')
      .update({ expires_at: new Date(Date.now() - 1000).toISOString() })
      .eq('token_hash', createHash('sha256').update(expiredToken).digest('hex'));
    expect(changed.error).toBeNull();
    const res = await call('post', '/api/auth/invites/accept', {
      token: expiredToken,
      password: PASSWORD,
    });
    expect(res.status).toBe(410);
    expect(res.body.error.code).toBe('INVITE_EXPIRED');
  });
  it.each([
    ['get', '/api/admin/plans'],
    ['get', '/api/admin/shops'],
    ['post', '/api/admin/shops'],
    ['post', '/api/admin/shops/:id/status'],
    ['post', '/api/admin/shops/:id/owner-invite'],
  ] as const)('an owner cannot call %s %s', async (method, path) => {
    const res = await call(method, path.replace(':id', shop), {}, owner, shop);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('SUPER_ADMIN_REQUIRED');
  });
  it('suspends the next request, login and shop selection; reactivation restores access', async () => {
    expect(
      (
        await call(
          'post',
          `/api/admin/shops/${shop}/status`,
          { status: 'suspended', reason: 'P01 test' },
          admin,
        )
      ).status,
    ).toBe(200);
    for (const res of [
      await call('get', '/api/auth/me', {}, owner, shop),
      await call('post', '/api/auth/login', { identifier: email, password: PASSWORD }),
      await call('post', '/api/auth/select-shop', { orgId: shop }, owner),
    ]) {
      expect(res.status, JSON.stringify(res.body)).toBe(403);
      expect(res.body.error.code).toBe('ORG_SUSPENDED');
    }
    expect(
      (await call('post', `/api/admin/shops/${shop}/status`, { status: 'active' }, admin)).status,
    ).toBe(200);
    expect((await call('get', '/api/auth/me', {}, owner, shop)).status).toBe(200);
  });
  it('links an existing account to a second shop without changing its password', async () => {
    const second = await provision(email, 'second');
    const secondToken = await readInviteToken(email);
    const lookup = await call('post', '/api/auth/invites/lookup', { token: secondToken });
    expect(InviteLookupResponse.parse(lookup.body).account_exists).toBe(true);
    const wrong = await call('post', '/api/auth/invites/accept', {
      token: secondToken,
      password: 'wrong',
    });
    expect(wrong.status).toBe(401);
    expect(wrong.body.error.code).toBe('INVALID_CREDENTIALS');
    expect(
      (await call('post', '/api/auth/invites/accept', { token: secondToken, password: PASSWORD }))
        .status,
    ).toBe(200);
    const session = await login(email);
    expect(session.requiresShopSelection).toBe(true);
    expect(session.shops.map((s) => s.orgId).sort()).toEqual([shop, second.organization_id].sort());
    const list = await call('get', `/api/admin/shops?search=p01-${STAMP}`, {}, admin);
    expect(list.status).toBe(200);
    expect(
      AdminShopsResponse.parse(list.body).items.filter((s) => s.owner_invite_status === 'accepted'),
    ).toHaveLength(2);
  });
});
