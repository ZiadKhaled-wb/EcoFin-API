// U01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates a supplier, lists it, edits it, reads its (empty) statement,
// archives and restores it; a duplicate active name is a 409; a warehouse user reads (one of the
// purchasing read keys, D53) but can't create; a collector can't even list.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  Supplier,
  SupplierList,
  SupplierStatement,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('U01 suppliers against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let warehouse: string;
  let collector: string;
  let org: string;
  let ip = 0;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.53.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.53.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'WAREHOUSE' | 'COLLECTOR', branchId: string) {
    const email = `u01.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
  async function auditCount(action: string, id: string) {
    const { count, error } = await service
      .from('audit_log')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', org)
      .eq('action', action)
      .eq('entity_id', id);
    expect(error).toBeNull();
    return count ?? 0;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `u01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.53.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'U01 shop',
        tenant_slug: `u01-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.53.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    warehouse = await login(await addEmployee('WAREHOUSE', main.data!.id));
    collector = await login(await addEmployee('COLLECTOR', main.data!.id));
  }, 60_000);

  it('owner: create, list, edit, empty statement, archive, restore', async () => {
    const created = await call('post', '/api/suppliers', owner, {
      name: '  Nile Traders ',
      phone: '010-1234 5678',
      payment_terms_days: 30,
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const supplier = Supplier.parse(created.body);
    expect(supplier).toMatchObject({
      name: 'Nile Traders',
      phone: '01012345678',
      payment_terms_days: 30,
      balance: '0.00',
      archived_at: null,
    });
    expect(await auditCount('supplier.created', supplier.id)).toBe(1);

    const list = await call('get', '/api/suppliers?search=nile');
    expect(list.status).toBe(200);
    expect(SupplierList.parse(list.body)).toMatchObject({ total: 1, page: 1 });
    const byPhone = await call('get', '/api/suppliers?search=' + encodeURIComponent('0101234'));
    expect(SupplierList.parse(byPhone.body).items.map((s) => s.id)).toEqual([supplier.id]);

    const edited = await call('patch', `/api/suppliers/${supplier.id}`, owner, {
      address: 'Giza',
      tax_registration_no: '123-456-789',
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    expect(Supplier.parse(edited.body)).toMatchObject({
      address: 'Giza',
      tax_registration_no: '123-456-789',
    });
    expect(await auditCount('supplier.updated', supplier.id)).toBe(1);
    const unchanged = await call('patch', `/api/suppliers/${supplier.id}`, owner, {
      address: 'Giza',
    });
    expect(unchanged.status).toBe(200);
    expect(await auditCount('supplier.updated', supplier.id)).toBe(1);

    const statement = await call('get', `/api/suppliers/${supplier.id}/statement`);
    expect(statement.status, JSON.stringify(statement.body)).toBe(200);
    expect(SupplierStatement.parse(statement.body)).toMatchObject({
      opening_balance: '0.00',
      closing_balance: '0.00',
      totals: { invoiced: '0.00', paid: '0.00', returned: '0.00' },
      rows: [],
      from: null,
      to: null,
    });
    const dated = await call(
      'get',
      `/api/suppliers/${supplier.id}/statement?from=2026-09-01&to=2026-09-30`,
    );
    expect(SupplierStatement.parse(dated.body)).toMatchObject({
      from: '2026-09-01',
      to: '2026-09-30',
    });
    const backwards = await call(
      'get',
      `/api/suppliers/${supplier.id}/statement?from=2026-09-30&to=2026-09-01`,
    );
    expect(backwards.status).toBe(400);

    const archived = await call('post', `/api/suppliers/${supplier.id}/archive`);
    expect(archived.status, JSON.stringify(archived.body)).toBe(200);
    expect(Supplier.parse(archived.body).archived_at).not.toBeNull();
    expect(await auditCount('supplier.archived', supplier.id)).toBe(1);
    const active = SupplierList.parse((await call('get', '/api/suppliers')).body);
    expect(active.items.map((s) => s.id)).not.toContain(supplier.id);
    const gone = await call('patch', `/api/suppliers/${supplier.id}`, owner, { notes: 'x' });
    expect(gone.status).toBe(404);
    expect(code(gone)).toBe('SUPPLIER_NOT_FOUND');

    const restored = await call('post', `/api/suppliers/${supplier.id}/restore`);
    expect(restored.status, JSON.stringify(restored.body)).toBe(200);
    expect(Supplier.parse(restored.body).archived_at).toBeNull();
    expect(await auditCount('supplier.restored', supplier.id)).toBe(1);
  });

  it('a duplicate active name (any letter case) or phone is a 409', async () => {
    const first = await call('post', '/api/suppliers', owner, {
      name: 'Delta Supply',
      phone: '+201000000777',
    });
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    const name = await call('post', '/api/suppliers', owner, { name: ' delta SUPPLY ' });
    expect(name.status).toBe(409);
    expect(code(name)).toBe('SUPPLIER_NAME_TAKEN');
    const phone = await call('post', '/api/suppliers', owner, {
      name: 'Other',
      phone: '+20 100 000 0777',
    });
    expect(phone.status).toBe(409);
    expect(code(phone)).toBe('SUPPLIER_PHONE_TAKEN');
    const bad = await call('post', '/api/suppliers', owner, { name: 'X', phone: 'abc' });
    expect(bad.status).toBe(400);
  });

  it('a warehouse user reads (200) but cannot write (403)', async () => {
    const created = await call('post', '/api/suppliers', owner, { name: 'Warehouse view' });
    const id = Supplier.parse(created.body).id;
    expect((await call('get', '/api/suppliers', warehouse)).status).toBe(200);
    expect((await call('get', `/api/suppliers/${id}`, warehouse)).status).toBe(200);
    expect((await call('get', `/api/suppliers/${id}/statement`, warehouse)).status).toBe(200);
    const create = await call('post', '/api/suppliers', warehouse, { name: 'Not allowed' });
    expect(create.status).toBe(403);
    expect(code(create)).toBe('PERMISSION_DENIED');
    expect((await call('patch', `/api/suppliers/${id}`, warehouse, { notes: 'x' })).status).toBe(
      403,
    );
    expect((await call('post', `/api/suppliers/${id}/archive`, warehouse)).status).toBe(403);
  });

  it('a collector gets 403 on the list, a supplier and a statement', async () => {
    const created = await call('post', '/api/suppliers', owner, { name: 'Collector view' });
    const id = Supplier.parse(created.body).id;
    const list = await call('get', '/api/suppliers', collector);
    expect(list.status).toBe(403);
    expect(code(list)).toBe('PERMISSION_DENIED');
    expect((await call('get', `/api/suppliers/${id}`, collector)).status).toBe(403);
    expect((await call('get', `/api/suppliers/${id}/statement`, collector)).status).toBe(403);
  });
});
