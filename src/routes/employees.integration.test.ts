// F06 HTTP against local Supabase: the real app (in-process, supertest) + local GoTrue + Postgres.
// Skipped unless RUN_INTEGRATION=1 (env: see src/routes/auth.integration.test.ts).
// The target employee is created here, unique per run, so the parallel suites aren't disturbed.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  MePermissionsResponse,
  ROLE_DEFAULT_PERMISSIONS,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SEED_PASSWORD = 'LocalDev-Only-2026!';
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const BR1 = 'd2000000-0000-0000-0000-000000000011';
const BR2 = 'd2000000-0000-0000-0000-000000000012';
const OWNER_ONE = 'd3000000-0000-0000-0000-000000000011';
const TARGET_PASSWORD = `F06-${Date.now()}!`;

// 198.18.1.0/24; the other integration files use other ranges.
let ipCounter = 0;
const nextIp = () => `198.18.1.${(ipCounter++ % 250) + 1}`;

describe.skipIf(!RUN)('F06 permissions over HTTP (local Supabase)', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let targetId: string;
  let managerId: string;
  const targetEmail = `f06.${Date.now()}@ecotech.test`;
  const managerEmail = `f06.manager.${Date.now()}@ecotech.test`;

  const call = (method: 'get' | 'put', path: string, token: string, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${token}`);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(identifier: string, password = SEED_PASSWORD) {
    const res = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier, password });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body).accessToken;
  }
  async function auditRows(action: string) {
    const { count, error } = await service
      .from('audit_log')
      .select('id', { count: 'exact', head: true })
      .eq('entity_id', targetId)
      .eq('action', action);
    if (error) throw new Error(error.message);
    return count ?? 0;
  }
  const myPermissions = async (token: string) => {
    const res = await call('get', '/api/me/permissions', token);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return MePermissionsResponse.parse(res.body);
  };

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const createEmployee = async (email: string, role: 'CASHIER' | 'BRANCH_MANAGER') => {
      const user = await service.auth.admin.createUser({
        email,
        password: TARGET_PASSWORD,
        email_confirm: true,
      });
      if (user.error) throw new Error(user.error.message);
      const emp = await service
        .from('employees')
        .insert({
          organization_id: SHOP_ONE,
          auth_user_id: user.data.user.id,
          full_name: `F06 ${role}`,
          email,
          username: email.split('@')[0],
          role,
          default_branch_id: BR1,
        })
        .select('id')
        .single();
      if (emp.error) throw new Error(emp.error.message);
      return emp.data.id;
    };
    targetId = await createEmployee(targetEmail, 'CASHIER');
    managerId = await createEmployee(managerEmail, 'BRANCH_MANAGER');
  });

  afterAll(async () => {
    for (const id of [targetId, managerId]) {
      if (!id) continue;
      await service
        .from('employees')
        .update({ is_active: false, archived_at: new Date().toISOString() })
        .eq('id', id);
    }
  });

  it('GET /api/me/permissions: a cashier gets exactly the CASHIER defaults and no branches yet', async () => {
    const me = await myPermissions(await login(targetEmail, TARGET_PASSWORD));
    expect([...me.keys].sort()).toEqual([...ROLE_DEFAULT_PERMISSIONS.CASHIER].sort());
    expect(me).toMatchObject({ branchIds: [], allBranches: false });
  });

  it('a cashier changing access -> 403 PERMISSION_DENIED (employee.manage), nothing written', async () => {
    const cashier = await login('cashier.one@ecotech.test');
    const before = await auditRows('employee.permission_set');
    const res = await call('put', `/api/employees/${targetId}/permissions`, cashier, {
      permissionKey: 'sale.void',
      granted: true,
      reason: 'should not work',
    });
    expect(res.status).toBe(403);
    expect(code(res)).toBe('PERMISSION_DENIED');
    expect(ErrorResponse.parse(res.body).error.details).toEqual({ permission: 'employee.manage' });
    const branches = await call('put', `/api/employees/${targetId}/branches`, cashier, {
      branchIds: [BR1],
      reason: 'should not work',
    });
    expect(branches.status).toBe(403);
    expect(await auditRows('employee.permission_set')).toBe(before);
  });

  it('the owner grants a key: 200, one audit row, and the target sees it on its next request', async () => {
    const owner = await login('owner.one@ecotech.test');
    const target = await login(targetEmail, TARGET_PASSWORD);
    expect((await myPermissions(target)).keys).not.toContain('sale.void');

    const res = await call('put', `/api/employees/${targetId}/permissions`, owner, {
      permissionKey: 'sale.void',
      granted: true,
      reason: 'covering the evening shift',
    });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body).toEqual({ employeeId: targetId, permissionKey: 'sale.void', granted: true });
    expect(await auditRows('employee.permission_set')).toBe(1);
    const { data } = await service
      .from('audit_log')
      .select('employee_id, organization_id, reason')
      .eq('entity_id', targetId)
      .eq('action', 'employee.permission_set')
      .single();
    expect(data).toEqual({
      employee_id: OWNER_ONE,
      organization_id: SHOP_ONE,
      reason: 'covering the evening shift',
    });
    expect((await myPermissions(target)).keys).toContain('sale.void');

    // Back to the role default: the key is gone again.
    const back = await call('put', `/api/employees/${targetId}/permissions`, owner, {
      permissionKey: 'sale.void',
      granted: false,
      reason: 'shift over',
    });
    expect(back.status).toBe(200);
    expect((await myPermissions(target)).keys).not.toContain('sale.void');
    expect(await auditRows('employee.permission_set')).toBe(2);
  });

  it('the owner sets branches: 200, one audit row, the target sees them', async () => {
    const owner = await login('owner.one@ecotech.test');
    const res = await call('put', `/api/employees/${targetId}/branches`, owner, {
      branchIds: [BR2, BR1],
      reason: 'covers both branches',
    });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body).toEqual({ employeeId: targetId, branchIds: [BR1, BR2].sort() });
    expect(await auditRows('employee.branches_set')).toBe(1);
    const target = await login(targetEmail, TARGET_PASSWORD);
    expect([...(await myPermissions(target)).branchIds].sort()).toEqual([BR1, BR2].sort());
  });

  it('bad requests: no reason, id in the body, bad id, the owner as target', async () => {
    const owner = await login('owner.one@ecotech.test');
    const put = (id: string, body: object) =>
      call('put', `/api/employees/${id}/permissions`, owner, body);

    const noReason = await put(targetId, {
      permissionKey: 'sale.void',
      granted: true,
      reason: ' ',
    });
    expect(noReason.status).toBe(400);
    expect(code(noReason)).toBe('VALIDATION_FAILED');
    const idInBody = await put(targetId, {
      employeeId: targetId,
      permissionKey: 'sale.void',
      granted: true,
      reason: 'x',
    });
    expect(idInBody.status).toBe(400);
    const badKey = await put(targetId, { permissionKey: 'sale.nope', granted: true, reason: 'x' });
    expect(badKey.status).toBe(400);
    const badId = await put('not-a-uuid', {
      permissionKey: 'sale.void',
      granted: true,
      reason: 'x',
    });
    expect(badId.status).toBe(400);
    const ownerTarget = await put(OWNER_ONE, {
      permissionKey: 'sale.void',
      granted: false,
      reason: 'x',
    });
    expect(ownerTarget.status).toBe(403);
    expect(code(ownerTarget)).toBe('FORBIDDEN');
  });

  it('D29 option 3: a manager given employee.manage grants only what they hold, never employee.manage, only own branches', async () => {
    const owner = await login('owner.one@ecotech.test');
    const ownerPut = (path: string, body: object) => call('put', path, owner, body);
    // The owner makes the branch manager a deputy (BR1 only) and gives the target both branches.
    expect(
      (
        await ownerPut(`/api/employees/${managerId}/permissions`, {
          permissionKey: 'employee.manage',
          granted: true,
          reason: 'deputy',
        })
      ).status,
    ).toBe(200);
    expect(
      (await ownerPut(`/api/employees/${managerId}/branches`, { branchIds: [BR1], reason: 'BR1' }))
        .status,
    ).toBe(200);
    expect(
      (
        await ownerPut(`/api/employees/${targetId}/branches`, {
          branchIds: [BR1, BR2],
          reason: 'both',
        })
      ).status,
    ).toBe(200);

    const manager = await login(managerEmail, TARGET_PASSWORD);
    const put = (path: string, body: object) => call('put', path, manager, body);
    const perm = (permissionKey: string, granted = true) =>
      put(`/api/employees/${targetId}/permissions`, {
        permissionKey,
        granted,
        reason: 'deputy test',
      });

    expect((await perm('cash.adjust')).status).toBe(200); // a BRANCH_MANAGER default
    const notHeld = await perm('export.data'); // not a BRANCH_MANAGER default
    expect(notHeld.status).toBe(403);
    expect(code(notHeld)).toBe('FORBIDDEN');
    const ownerOnly = await perm('employee.manage');
    expect(ownerOnly.status).toBe(403);
    expect(code(ownerOnly)).toBe('FORBIDDEN');

    // BR2 stays untouched: allowed. Removing BR2 (not the manager's): refused.
    const keepForeign = await put(`/api/employees/${targetId}/branches`, {
      branchIds: [BR2],
      reason: 'leaves BR1',
    });
    expect(keepForeign.status, JSON.stringify(keepForeign.body)).toBe(200);
    const removeForeign = await put(`/api/employees/${targetId}/branches`, {
      branchIds: [],
      reason: 'x',
    });
    expect(removeForeign.status).toBe(403);
    expect(code(removeForeign)).toBe('FORBIDDEN');
  });
});
