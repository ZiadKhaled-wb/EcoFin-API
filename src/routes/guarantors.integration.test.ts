// R04 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates a customer and a guarantor with a link, links an existing guarantor,
// reads the customer's list, edits the customer and reads the same list again, uploads a guarantor
// ID photo, unlinks one; a cashier (customer.create, no guarantor.manage) creates and links but
// can't unlink, edit or archive; the requirement read follows the published policy.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CustomerGuarantorList,
  ErrorResponse,
  Guarantor,
  GuarantorDetails,
  GuarantorList,
  GuarantorNationalIdTakenDetail,
  GuarantorRequirement,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]);
let serial = 0;
/** A valid national ID that is new on every call. */
const nationalId = () =>
  `2900101${String(1).padStart(2, '0')}${String(10000 + ++serial).padStart(5, '0')}`;

describe.skipIf(!RUN)('R04 guarantors against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let collector: string;
  let org: string;
  let ip = 0;
  const nextIp = () => `198.18.71.${(++ip % 250) + 1}`;
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
  async function newShop(tag: string) {
    const email = `r04.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `R04 ${tag}`,
        tenant_slug: `r04-${tag}-${STAMP}`,
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
    const email = `r04.${role.toLowerCase()}.${STAMP}@ecotech.test`;
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
  async function newCustomer(name: string, token = owner) {
    const r = await call('post', '/api/customers', token, {
      full_name: `${name} ${STAMP}`,
      phones: ['01500000010'],
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return (r.body as { id: string }).id;
  }
  async function newGuarantor(name: string, token = owner, link?: object) {
    const r = await call('post', '/api/guarantors', token, {
      full_name: `${name} ${STAMP}`,
      phone: '01500000011',
      national_id: nationalId(),
      ...(link ? { link } : {}),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return Guarantor.parse(r.body);
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

  it('owner: create with a link, link an existing one, edit the customer, the list stays', async () => {
    const customerId = await newCustomer('Customer One');
    const first = await newGuarantor('Guarantor One', owner, {
      customer_id: customerId,
      relation: 'father',
    });
    expect(first.national_id).toMatch(/^\d{14}$/);
    expect(first.birth_date).toBe('1990-01-01');
    const second = await newGuarantor('Guarantor Two');
    const linked = await call('post', `/api/customers/${customerId}/guarantors`, owner, {
      guarantor_id: second.id,
      relation: 'colleague',
    });
    expect(linked.status, JSON.stringify(linked.body)).toBe(201);
    expect(CustomerGuarantorList.parse(linked.body)).toHaveLength(2);

    const list = await call('get', `/api/customers/${customerId}/guarantors`);
    expect(list.status).toBe(200);
    expect(
      CustomerGuarantorList.parse(list.body).map((g) => [g.id, g.relation, g.on_active_contract]),
    ).toEqual([
      [first.id, 'father', false],
      [second.id, 'colleague', false],
    ]);

    // Done when: editing the customer never deletes their guarantors.
    const edited = await call('patch', `/api/customers/${customerId}`, owner, {
      notes: 'edited',
      phones: ['01500000012', '01500000013'],
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    const again = await call('get', `/api/customers/${customerId}/guarantors`);
    expect(CustomerGuarantorList.parse(again.body).map((g) => [g.id, g.relation])).toEqual([
      [first.id, 'father'],
      [second.id, 'colleague'],
    ]);

    const relation = await call(
      'patch',
      `/api/customers/${customerId}/guarantors/${second.id}`,
      owner,
      {
        relation: 'friend',
      },
    );
    expect(relation.status, JSON.stringify(relation.body)).toBe(200);
    const duplicate = await call('post', `/api/customers/${customerId}/guarantors`, owner, {
      guarantor_id: second.id,
      relation: 'friend',
    });
    expect(duplicate.status).toBe(409);
    expect(code(duplicate)).toBe('GUARANTOR_ALREADY_LINKED');

    const unlinked = await call(
      'post',
      `/api/customers/${customerId}/guarantors/${first.id}/unlink`,
    );
    expect(unlinked.status, JSON.stringify(unlinked.body)).toBe(200);
    expect(CustomerGuarantorList.parse(unlinked.body).map((g) => g.id)).toEqual([second.id]);
    const details = GuarantorDetails.parse((await call('get', `/api/guarantors/${first.id}`)).body);
    expect(details.customers).toEqual([]);
  });

  it('a duplicate national ID is a 409 that names the guarantor; a bad body is a 400', async () => {
    const one = await newGuarantor('Duplicate Holder');
    const taken = await call('post', '/api/guarantors', owner, {
      full_name: 'Twin Guarantor',
      phone: '01500000014',
      national_id: one.national_id,
    });
    expect(taken.status).toBe(409);
    expect(code(taken)).toBe('GUARANTOR_NATIONAL_ID_TAKEN');
    expect(GuarantorNationalIdTakenDetail.parse(taken.body.error.details)).toEqual({
      guarantor_id: one.id,
      full_name: one.full_name,
    });
    const noId = await call('post', '/api/guarantors', owner, {
      full_name: 'No Id',
      phone: '01500000015',
    });
    expect(noId.status).toBe(400);
    const badId = await call('post', '/api/guarantors', owner, {
      full_name: 'Bad Id',
      phone: '01500000015',
      national_id: '49001010100015',
    });
    expect(badId.status).toBe(400);
  });

  it('ID photos: the entity type guarantor is accepted and counted', async () => {
    const g = await newGuarantor('Photo Guarantor');
    const upload = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + owner)
      .set('x-org-id', org)
      .field('purpose', 'customer_id')
      .field('entityType', 'guarantor')
      .field('entityId', g.id)
      .attach('file', PNG, { filename: 'id-front.png', contentType: 'image/png' });
    expect(upload.status, JSON.stringify(upload.body)).toBe(201);
    const read = Guarantor.parse((await call('get', `/api/guarantors/${g.id}`)).body);
    expect(read.id_photos_count).toBe(1);
    const files = await call('get', `/api/files?entityType=guarantor&entityId=${g.id}`);
    expect(files.status, JSON.stringify(files.body)).toBe(200);
    expect((files.body as { items: unknown[] }).items).toHaveLength(1);
  });

  it('a cashier creates and links but cannot unlink, edit or archive; a collector only reads', async () => {
    const customerId = await newCustomer('Cashier Customer', cashier);
    const g = await newGuarantor('Cashier Guarantor', cashier, {
      customer_id: customerId,
      relation: 'neighbour',
    });
    // Masked: a cashier has no customer.view_pii.
    expect(g.national_id).toBeNull();
    expect(g.national_id_masked).toMatch(/^\*{10}\d{4}$/);
    expect(g.birth_date).toBeNull();
    const other = await newGuarantor('Cashier Other', cashier);
    const linked = await call('post', `/api/customers/${customerId}/guarantors`, cashier, {
      guarantor_id: other.id,
      relation: 'friend',
    });
    expect(linked.status, JSON.stringify(linked.body)).toBe(201);

    for (const [method, path, body] of [
      ['post', `/api/customers/${customerId}/guarantors/${g.id}/unlink`, undefined],
      ['patch', `/api/customers/${customerId}/guarantors/${g.id}`, { relation: 'other' }],
      ['patch', `/api/guarantors/${g.id}`, { job: 'Nope' }],
      ['post', `/api/guarantors/${g.id}/archive`, undefined],
      ['post', `/api/guarantors/${g.id}/restore`, undefined],
    ] as const) {
      const denied = await call(method, path, cashier, body);
      expect(denied.status, path).toBe(403);
      expect(code(denied)).toBe('PERMISSION_DENIED');
    }

    const read = await call('get', `/api/customers/${customerId}/guarantors`, collector);
    expect(read.status).toBe(200);
    expect(CustomerGuarantorList.parse(read.body).every((x) => x.national_id === null)).toBe(true);
    const list = await call(
      'get',
      '/api/guarantors?search=' + encodeURIComponent('Cashier'),
      collector,
    );
    expect(GuarantorList.parse(list.body).total).toBe(2);
    const create = await call('post', '/api/guarantors', collector, {
      full_name: 'Not Allowed',
      phone: '01500000016',
      national_id: nationalId(),
    });
    expect(create.status).toBe(403);
    expect(code(create)).toBe('PERMISSION_DENIED');
  });

  it('archive and restore, and the owner edits with the national ID', async () => {
    const g = await newGuarantor('Archive Guarantor');
    const archived = await call('post', `/api/guarantors/${g.id}/archive`);
    expect(archived.status, JSON.stringify(archived.body)).toBe(200);
    expect(Guarantor.parse(archived.body).archived_at).not.toBeNull();
    expect(
      GuarantorList.parse((await call('get', '/api/guarantors?search=Archive')).body).total,
    ).toBe(0);
    expect(
      GuarantorList.parse(
        (await call('get', '/api/guarantors?status=archived&search=Archive')).body,
      ).total,
    ).toBe(1);
    const customerId = await newCustomer('Archive Customer');
    const refused = await call('post', `/api/customers/${customerId}/guarantors`, owner, {
      guarantor_id: g.id,
      relation: 'friend',
    });
    expect(refused.status).toBe(409);
    expect(code(refused)).toBe('GUARANTOR_ARCHIVED');
    const restored = await call('post', `/api/guarantors/${g.id}/restore`);
    expect(Guarantor.parse(restored.body).archived_at).toBeNull();

    const edited = await call('patch', `/api/guarantors/${g.id}`, owner, {
      job: 'Driver',
      national_id: nationalId(),
    });
    expect(edited.status, JSON.stringify(edited.body)).toBe(200);
    expect(Guarantor.parse(edited.body).job).toBe('Driver');
    const rows = await service
      .from('audit_log')
      .select('action, severity, after')
      .eq('organization_id', org)
      .eq('entity_id', g.id)
      .eq('action', 'guarantor.updated');
    expect(rows.error).toBeNull();
    expect(rows.data).toHaveLength(1);
    expect(rows.data![0]!.severity).toBe('warning');
    expect(JSON.stringify(rows.data![0]!.after)).not.toMatch(/\d{14}/);
  });

  it('the requirement follows the published policy', async () => {
    const customerId = await newCustomer('Requirement Customer');
    const before = GuarantorRequirement.parse(
      (
        await call(
          'get',
          `/api/customers/${customerId}/guarantor-requirement?financed_amount=15000.00`,
        )
      ).body,
    );
    expect(before).toMatchObject({ required_above: null, required_count: 0, met: true });

    const published = await call('post', '/api/settings/installment-policies', owner, {
      guarantor_required_above: '10000.00',
      guarantors_required_count: 2,
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const url = (amount: string) =>
      `/api/customers/${customerId}/guarantor-requirement?financed_amount=${amount}`;
    const over = GuarantorRequirement.parse((await call('get', url('15000.00'))).body);
    expect(over).toMatchObject({
      required_above: '10000.00',
      required_count: 2,
      linked_active_count: 0,
      met: false,
    });
    expect(GuarantorRequirement.parse((await call('get', url('10000.00'))).body)).toMatchObject({
      required_count: 0,
      met: true,
    });

    await newGuarantor('Requirement One', owner, { customer_id: customerId, relation: 'father' });
    const one = GuarantorRequirement.parse((await call('get', url('15000.00'))).body);
    expect(one).toMatchObject({ linked_active_count: 1, met: false });
    await newGuarantor('Requirement Two', owner, { customer_id: customerId, relation: 'mother' });
    const two = GuarantorRequirement.parse((await call('get', url('15000.00'))).body);
    expect(two).toMatchObject({ linked_active_count: 2, met: true });

    const bad = await call('get', url('abc'));
    expect(bad.status).toBe(400);
    const missing = await call('get', `/api/customers/${customerId}/guarantor-requirement`);
    expect(missing.status).toBe(400);
  });
});
