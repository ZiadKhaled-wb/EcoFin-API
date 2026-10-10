// R01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates a customer with a national ID, finds it, edits it, blocks and
// unblocks it; a duplicate national ID is a 409 naming who has it; a cashier (customer.create, no
// customer.view_pii) only ever gets masked IDs and can't edit; a collector reads masked; a
// warehouse user can't read; ID photos count for everyone but only customer.view_pii lists them;
// a starter shop (no customers module) is refused.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  Customer,
  CustomerList,
  CustomerNationalIdTakenDetail,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const NATIONAL_ID = '29001010100015';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]);

describe.skipIf(!RUN)('R01 customers against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let collector: string;
  let warehouse: string;
  let org: string;
  let ip = 0;
  const nextIp = () => `198.18.63.${(++ip % 250) + 1}`;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
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
  async function newShop(tag: string, plan: 'retail' | 'starter') {
    const email = `r01.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `R01 ${tag}`,
        tenant_slug: `r01-${tag}-${STAMP}`,
        plan_key: plan,
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
  async function addEmployee(role: 'CASHIER' | 'COLLECTOR' | 'WAREHOUSE', branchId: string) {
    const email = `r01.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
  async function auditRows(action: string, id: string) {
    const { data, error } = await service
      .from('audit_log')
      .select('severity, reason, before, after')
      .eq('organization_id', org)
      .eq('action', action)
      .eq('entity_id', id);
    expect(error).toBeNull();
    return data ?? [];
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = await login('superadmin@ecotech.test');
    const shop = await newShop('main', 'retail');
    org = shop.id;
    owner = shop.token;
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    cashier = await login(await addEmployee('CASHIER', main.data!.id));
    collector = await login(await addEmployee('COLLECTOR', main.data!.id));
    warehouse = await login(await addEmployee('WAREHOUSE', main.data!.id));
  }, 90_000);

  it('owner: create with a national ID, search, edit, block, unblock', async () => {
    const created = await call('post', '/api/customers', owner, {
      full_name: '  Ahmed   Ali  Hassan ',
      phones: [' +20 100 123 4567 ', '02-2345 6789'],
      national_id: ' 2900101-0100015 ',
      monthly_income: '8500.5',
      city: 'Cairo',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const customer = Customer.parse(created.body);
    expect(customer).toMatchObject({
      full_name: 'Ahmed Ali Hassan',
      phones: ['01001234567', '0223456789'],
      national_id: NATIONAL_ID,
      national_id_masked: '**********0015',
      birth_date: '1990-01-01',
      gender: 'male',
      monthly_income: '8500.50',
      status: 'active',
      id_photos_count: 0,
    });
    const createdAudit = await auditRows('customer.created', customer.id);
    expect(createdAudit).toHaveLength(1);
    expect(JSON.stringify(createdAudit)).not.toContain(NATIONAL_ID);
    expect(JSON.stringify(createdAudit)).toContain('**********0015');

    for (const search of ['AHMED', '0100123', '+20 100 123 4567', NATIONAL_ID, '2900']) {
      const list = await call('get', '/api/customers?search=' + encodeURIComponent(search));
      expect(list.status, search).toBe(200);
      expect(
        CustomerList.parse(list.body).items.map((c) => c.id),
        search,
      ).toEqual([customer.id]);
    }

    const edited = await call('patch', `/api/customers/${customer.id}`, owner, {
      address: 'Giza',
      job: 'Engineer',
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    expect(Customer.parse(edited.body)).toMatchObject({ address: 'Giza', job: 'Engineer' });
    const unchanged = await call('patch', `/api/customers/${customer.id}`, owner, {
      address: ' Giza ',
    });
    expect(unchanged.status).toBe(200);
    expect(await auditRows('customer.updated', customer.id)).toHaveLength(1);
    const contradicts = await call('patch', `/api/customers/${customer.id}`, owner, {
      birth_date: '1990-01-02',
    });
    expect(contradicts.status).toBe(400);

    const noReason = await call('post', `/api/customers/${customer.id}/status`, owner, {
      status: 'blocked',
    });
    expect(noReason.status).toBe(400);
    const blocked = await call('post', `/api/customers/${customer.id}/status`, owner, {
      status: 'blocked',
      reason: 'bounced three cheques',
    });
    expect(blocked.status, JSON.stringify(blocked.body)).toBe(200);
    expect(Customer.parse(blocked.body).status).toBe('blocked');
    const onlyBlocked = CustomerList.parse(
      (await call('get', '/api/customers?status=blocked')).body,
    );
    expect(onlyBlocked.items.map((c) => c.id)).toEqual([customer.id]);
    const unblocked = await call('post', `/api/customers/${customer.id}/status`, owner, {
      status: 'active',
    });
    expect(Customer.parse(unblocked.body).status).toBe('active');
    const statusAudit = await auditRows('customer.status_set', customer.id);
    expect(statusAudit).toHaveLength(2);
    expect(statusAudit.map((a) => a.severity).sort()).toEqual(['info', 'warning']);
    expect(statusAudit.some((a) => a.reason === 'bounced three cheques')).toBe(true);
  });

  it('a duplicate national ID is a 409 that names who has it; a bad ID is a 400', async () => {
    const existing = CustomerList.parse(
      (await call('get', '/api/customers?search=' + NATIONAL_ID)).body,
    ).items[0]!;
    const twin = await call('post', '/api/customers', owner, {
      full_name: 'Twin',
      phones: ['01000000002'],
      national_id: '2-900101-01-00015',
    });
    expect(twin.status).toBe(409);
    expect(code(twin)).toBe('CUSTOMER_NATIONAL_ID_TAKEN');
    expect(
      CustomerNationalIdTakenDetail.parse(ErrorResponse.parse(twin.body).error.details),
    ).toEqual({ customer_id: existing.id, full_name: 'Ahmed Ali Hassan' });
    expect(JSON.stringify(twin.body)).not.toContain(NATIONAL_ID);
    for (const national_id of ['49001010100015', '29002300100015', '2900101010001']) {
      const bad = await call('post', '/api/customers', owner, {
        full_name: 'Bad',
        phones: ['01000000003'],
        national_id,
      });
      expect(bad.status, national_id).toBe(400);
    }
  });

  it('a cashier (no customer.view_pii) only ever sees masked IDs and cannot edit', async () => {
    const created = await call('post', '/api/customers', cashier, {
      full_name: 'Cashier Customer',
      phones: ['01500000001'],
      national_id: '29211051300079',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    expect(Customer.parse(created.body)).toMatchObject({
      national_id: null,
      national_id_masked: '**********0079',
      birth_date: '1992-11-05',
    });
    expect(JSON.stringify(created.body)).not.toContain('29211051300079');

    const list = await call('get', '/api/customers', cashier);
    expect(list.status).toBe(200);
    const items = CustomerList.parse(list.body).items;
    expect(items.length).toBeGreaterThanOrEqual(2);
    expect(items.every((c) => c.national_id === null)).toBe(true);
    expect(JSON.stringify(list.body)).not.toMatch(/\d{14}/);

    const whole = await call('get', '/api/customers?search=' + NATIONAL_ID, cashier);
    const found = CustomerList.parse(whole.body).items;
    expect(found.map((c) => c.full_name)).toEqual(['Ahmed Ali Hassan']);
    expect(found[0]!.national_id).toBeNull();
    const prefix = await call('get', '/api/customers?search=2900', cashier);
    expect(CustomerList.parse(prefix.body).total).toBe(0);

    const one = await call('get', `/api/customers/${found[0]!.id}`, cashier);
    expect(Customer.parse(one.body)).toMatchObject({
      national_id: null,
      national_id_masked: '**********0015',
    });
    const duplicate = await call('post', '/api/customers', cashier, {
      full_name: 'Twin',
      phones: ['01500000002'],
      national_id: NATIONAL_ID,
    });
    expect(duplicate.status).toBe(409);
    const edit = await call('patch', `/api/customers/${found[0]!.id}`, cashier, { notes: 'x' });
    expect(edit.status).toBe(403);
    expect(code(edit)).toBe('PERMISSION_DENIED');
    const block = await call('post', `/api/customers/${found[0]!.id}/status`, cashier, {
      status: 'blocked',
      reason: 'not allowed',
    });
    expect(block.status).toBe(403);
  });

  it('ID photos: counted for everyone, listed only with customer.view_pii', async () => {
    const id = CustomerList.parse((await call('get', '/api/customers?search=' + NATIONAL_ID)).body)
      .items[0]!.id;
    const upload = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + owner)
      .set('x-org-id', org)
      .field('purpose', 'customer_id')
      .field('entityType', 'customer')
      .field('entityId', id)
      .attach('file', PNG, { filename: 'id-front.png', contentType: 'image/png' });
    expect(upload.status, JSON.stringify(upload.body)).toBe(201);

    expect(Customer.parse((await call('get', `/api/customers/${id}`)).body).id_photos_count).toBe(
      1,
    );
    expect(
      Customer.parse((await call('get', `/api/customers/${id}`, cashier)).body).id_photos_count,
    ).toBe(1);
    const files = (token: string) =>
      call('get', `/api/files?entityType=customer&entityId=${id}`, token);
    const forOwner = await files(owner);
    expect(forOwner.status, JSON.stringify(forOwner.body)).toBe(200);
    expect((forOwner.body as { items: unknown[] }).items).toHaveLength(1);
    const forCashier = await files(cashier);
    expect(forCashier.status).toBe(200);
    expect((forCashier.body as { items: unknown[] }).items).toHaveLength(0);
    const cashierUpload = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + cashier)
      .set('x-org-id', org)
      .field('purpose', 'customer_id')
      .field('entityType', 'customer')
      .field('entityId', id)
      .attach('file', PNG, { filename: 'id-back.png', contentType: 'image/png' });
    expect(cashierUpload.status).toBe(403);
  });

  it('a collector reads masked and cannot write; a warehouse user cannot read', async () => {
    const list = await call('get', '/api/customers', collector);
    expect(list.status).toBe(200);
    expect(CustomerList.parse(list.body).items.every((c) => c.national_id === null)).toBe(true);
    const create = await call('post', '/api/customers', collector, {
      full_name: 'Not allowed',
      phones: ['01500000003'],
    });
    expect(create.status).toBe(403);
    expect(code(create)).toBe('PERMISSION_DENIED');

    const denied = await call('get', '/api/customers', warehouse);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const id = CustomerList.parse(list.body).items[0]!.id;
    expect((await call('get', `/api/customers/${id}`, warehouse)).status).toBe(403);
  });

  it('a plan without the customers module is refused', async () => {
    const starter = await newShop('starter', 'starter');
    const send = (method: 'get' | 'post', body?: object) => {
      const r = request(app)
        [method]('/api/customers')
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', 'Bearer ' + starter.token)
        .set('x-org-id', starter.id);
      return body ? r.send(body) : r;
    };
    const list = await send('get');
    expect(list.status).toBe(403);
    expect(code(list)).toBe('MODULE_NOT_IN_PLAN');
    const create = await send('post', { full_name: 'Starter', phones: ['01500000004'] });
    expect(create.status).toBe(403);
    expect(code(create)).toBe('MODULE_NOT_IN_PLAN');
  });
});
