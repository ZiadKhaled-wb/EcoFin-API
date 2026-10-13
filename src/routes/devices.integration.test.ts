// O03 against local Supabase and a fake ETA (RUN_INTEGRATION=1, env as in auth.integration.test.ts).
// A fresh shop on the starter plan (2 devices) creates its POS devices and can't make a third.
// The owner makes a pairing code, a cashier types it on the POS computer and gets a device token;
// from then on the computer is that device: the cashier opens a shift on it and sells, the sale
// carries the device and its ETA receipt is prepared and accepted. A device id made up by the
// client is ignored everywhere. An unpaired or turned-off device is refused on its next request.
// Another shop can do nothing with the device, its code or its token. The database holds only
// hashes, and no log row of the shop holds a code or a token.
import { createHash } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CurrentDeviceResponse,
  DeviceCreated,
  DeviceList,
  DevicePaired,
  DevicePairingCode,
  ErrorResponse,
  Sale,
  Shift,
  isPairingCode,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { EtaClient } from '../eta/client';
import { etaHosts } from '../eta/config';
import { etaJobHandlers } from '../eta/jobs';
import { supabaseEtaStore } from '../eta/store';
import { supabaseJobStore } from '../jobs/store';
import { JobWorker } from '../jobs/worker';
import { startFakeEta, type FakeEta } from '../test/fake-eta';
import { readInviteToken } from '../test/inviteMail';
import { getEnv } from '../utils/env';
import { createLogger } from '../utils/logger';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const CLIENT_ID = `o03-client-${STAMP}`;
const SECRET = `o03-secret-${STAMP}`;
const SERIAL = `O03-POS-${STAMP}`;
const KEY = `o03-preshared-${STAMP}`;
const RIN = '674859545';
const ETA_ENV = ['ETA_PREPROD_ID_URL', 'ETA_PREPROD_API_URL', 'ETA_PREPROD_PORTAL_URL'] as const;
const sha256 = (value: string) => createHash('sha256').update(value, 'utf8').digest('hex');

interface CallOptions {
  key?: string;
  /** Sent as x-device-token: the request comes from that paired computer. */
  pos?: string;
  /** Sent as a hand-made x-device-id, which the API must ignore. */
  deviceId?: string;
  orgId?: string;
  requestId?: string;
}

describe.skipIf(!RUN)('O03 POS devices against local stack and a fake ETA', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let fake: FakeEta;
  let worker: JobWorker;
  let owner: string;
  let cashier: string;
  let otherOwner: string;
  let org: string;
  let otherOrg: string;
  let branch: string;
  let pos1: string;
  let pos2: string;
  let tv: string;
  /** The device token of the computer the cashier paired with POS-1. */
  let token = '';
  let firstCode = '';
  const savedEnv = new Map<string, string | undefined>();
  let ip = 0;

  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    bearer: string,
    body?: object,
    options: CallOptions = {},
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.93.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + bearer);
    const orgId = options.orgId ?? (bearer === otherOwner ? otherOrg : org);
    if (orgId) r.set('x-org-id', orgId);
    if (options.key) r.set('Idempotency-Key', options.key);
    if (options.pos) r.set('x-device-token', options.pos);
    if (options.deviceId) r.set('x-device-id', options.deviceId);
    if (options.requestId) r.set('x-request-id', options.requestId);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.93.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function provision(tag: string) {
    const admin = await login('superadmin@ecotech.test');
    const email = `o03.owner.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.93.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `O03 shop ${tag}`,
        tenant_slug: `o03-${tag}-${STAMP}`,
        plan_key: 'starter',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.93.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    return { org: shop.body.organization_id as string, token: await login(email) };
  }
  async function deviceRow(id: string) {
    const { data, error } = await service
      .from('devices')
      .select(
        'id, name, branch_id, is_active, token_hash, pairing_code_hash, pairing_expires_at, paired_at, paired_by, last_seen_at',
      )
      .eq('id', id)
      .single();
    if (error) throw new Error(error.message);
    return data;
  }
  async function auditOf(requestId: string) {
    const { data, error } = await service
      .from('audit_log')
      .select('action, device_id, organization_id')
      .eq('request_id', requestId);
    if (error) throw new Error(error.message);
    return data as { action: string; device_id: string | null; organization_id: string }[];
  }
  /** A new pairing code for a device, as the owner's screen gets it. */
  async function newCode(device: string) {
    const res = await call('post', `/api/devices/${device}/pairing-code`, owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return DevicePairingCode.parse(res.body);
  }
  /** Runs the shop's ETA jobs until none is left. */
  async function drain(timeoutMs = 20_000) {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const result = await worker.tick();
      const { data, error } = await service
        .from('jobs')
        .select('job_type, status, last_error')
        .eq('organization_id', org)
        .like('job_type', 'eta.%')
        .in('status', ['queued', 'running', 'failed', 'dead']);
      if (error) throw new Error(error.message);
      const open = data as { job_type: string; status: string; last_error: string | null }[];
      const broken = open.filter((job) => job.status === 'failed' || job.status === 'dead');
      if (broken.length > 0) throw new Error(`an ETA job failed: ${JSON.stringify(broken)}`);
      if (open.length === 0) return;
      if (Date.now() > until) throw new Error(`ETA jobs did not drain: ${JSON.stringify(open)}`);
      if (result.succeeded === 0) await new Promise((resolve) => setTimeout(resolve, 150));
    }
  }

  beforeAll(async () => {
    fake = await startFakeEta({
      clientId: CLIENT_ID,
      clientSecret: SECRET,
      posSerial: SERIAL,
      presharedKey: KEY,
    });
    for (const name of ETA_ENV) savedEnv.set(name, process.env[name]);
    process.env['ETA_PREPROD_ID_URL'] = fake.url;
    process.env['ETA_PREPROD_API_URL'] = fake.url;
    process.env['ETA_PREPROD_PORTAL_URL'] = 'https://portal.fake-eta.test';
    const env = getEnv();
    expect(env.ETA_PREPROD_API_URL).toBe(fake.url);
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const logger = createLogger({ level: 'silent' });
    const hosts = etaHosts(env);
    worker = new JobWorker({
      store: supabaseJobStore(service),
      handlers: etaJobHandlers({
        store: supabaseEtaStore(service),
        client: new EtaClient({ hosts, logger, timeoutMs: 5000 }),
        hosts,
        logger,
        lookupGapMs: 0,
        retryDelaysSeconds: [0],
        pollDelaysSeconds: [0],
      }),
      logger,
      batchSize: 50,
    });

    const mine = await provision('a');
    org = mine.org;
    owner = mine.token;
    const other = await provision('b');
    otherOrg = other.org;
    otherOwner = other.token;

    const named = await service
      .from('organizations')
      .update({ tax_registration_no: RIN, legal_name: 'O03 Furniture LLC' })
      .eq('id', org);
    expect(named.error).toBeNull();
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const addressed = await call('patch', `/api/branches/${branch}`, owner, {
      name: 'Main',
      address: '16 Abbas El Akkad',
      city: 'Nasr City',
      governorate: 'Cairo',
      eta_branch_code: '0',
      building_number: '14',
    });
    expect(addressed.status, JSON.stringify(addressed.body)).toBe(200);

    const cashierEmail = `o03.cashier.${STAMP}@ecotech.test`;
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

    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون 55 بوصة',
      sku: 'O03-TV',
      cash_price: '1140.00',
      eta_item_code: `EG-${RIN}-TV55`,
      eta_item_type: 'EGS',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 10 }] },
      { key: `o03-it-stock-${STAMP}` },
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
  }, 120_000);

  afterAll(async () => {
    // Nothing of this shop may be left for a real worker: ETA off, its jobs gone.
    if (org) {
      await service.from('eta_settings').update({ is_enabled: false }).eq('organization_id', org);
      await service.from('jobs').delete().eq('organization_id', org).like('job_type', 'eta.%');
    }
    await fake?.close();
    for (const [name, value] of savedEnv) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  it('the owner creates the devices the plan allows; one more fails', async () => {
    const first = await call('post', '/api/devices', owner, { branch_id: branch, name: ' POS-1 ' });
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    pos1 = DeviceCreated.parse(first.body).id;
    const taken = await call('post', '/api/devices', owner, { branch_id: branch, name: 'pos-1' });
    expect(taken.status).toBe(409);
    expect(code(taken)).toBe('DEVICE_NAME_TAKEN');
    const second = await call('post', '/api/devices', owner, { branch_id: branch, name: 'POS-2' });
    expect(second.status, JSON.stringify(second.body)).toBe(201);
    pos2 = DeviceCreated.parse(second.body).id;

    // Starter allows 2 devices.
    const third = await call('post', '/api/devices', owner, { branch_id: branch, name: 'POS-3' });
    expect(third.status).toBe(409);
    expect(code(third)).toBe('PLAN_LIMIT_REACHED');
    expect(third.body.error.details).toMatchObject({ limit: 2, used: 2 });

    const denied = await call('post', '/api/devices', cashier, { branch_id: branch, name: 'X' });
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const blank = await call('post', '/api/devices', owner, { branch_id: branch, name: '  ' });
    expect(blank.status).toBe(400);

    const list = await call('get', '/api/devices', owner);
    expect(list.status).toBe(200);
    expect(DeviceList.parse(list.body).map((d) => [d.name, d.is_active, d.paired])).toEqual([
      ['POS-1', true, false],
      ['POS-2', true, false],
    ]);

    const registered = await call('put', `/api/devices/${pos1}/eta`, owner, {
      eta_serial: SERIAL,
      eta_os_version: 'android 14',
      eta_model_framework: '1',
      preshared_key: KEY,
      eta_status: 'active',
    });
    expect(registered.status, JSON.stringify(registered.body)).toBe(200);
    const settings = await call('put', '/api/eta/settings', owner, {
      environment: 'preprod',
      client_id: CLIENT_ID,
      client_secret: SECRET,
      activity_code: '4753',
      is_enabled: true,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
  });

  it('a pairing code turns a computer into the device; only hashes are stored', async () => {
    const before = Date.now();
    const made = await newCode(pos1);
    firstCode = made.code;
    expect(isPairingCode(made.code)).toBe(true);
    const ttl = new Date(made.expires_at).getTime() - before;
    expect(ttl).toBeGreaterThan(14 * 60_000);
    expect(ttl).toBeLessThanOrEqual(15 * 60_000 + 5000);
    const stored = await deviceRow(pos1);
    expect(stored.pairing_code_hash).toBe(sha256(made.code));
    expect(stored.token_hash).toBeNull();

    // A cashier can't make a code, and a wrong one is just an invalid code.
    const denied = await call('post', `/api/devices/${pos1}/pairing-code`, cashier);
    expect(denied.status).toBe(403);
    const wrong = await call('post', '/api/devices/pair', cashier, {
      code: made.code.replace(/.$/, made.code.endsWith('A') ? 'B' : 'A'),
    });
    expect(wrong.status).toBe(400);
    expect(code(wrong)).toBe('PAIRING_CODE_INVALID');
    expect((await deviceRow(pos1)).pairing_code_hash).toBe(sha256(made.code));

    // Typed the way people type: lower case, with a dash.
    const typed = `${made.code.slice(0, 4)}-${made.code.slice(4)}`.toLowerCase();
    const paired = await call('post', '/api/devices/pair', cashier, { code: typed });
    expect(paired.status, JSON.stringify(paired.body)).toBe(200);
    const answer = DevicePaired.parse(paired.body);
    token = answer.device_token;
    expect(Buffer.from(token, 'base64url')).toHaveLength(32);
    expect(answer.device).toEqual({
      id: pos1,
      name: 'POS-1',
      branch_id: branch,
      branch_name: 'Main',
    });
    const row = await deviceRow(pos1);
    expect(row.token_hash).toBe(sha256(token));
    expect(row.pairing_code_hash).toBeNull();
    expect(row.pairing_expires_at).toBeNull();
    expect(row.paired_at).not.toBeNull();

    // The code is used up.
    const again = await call('post', '/api/devices/pair', cashier, { code: made.code });
    expect(again.status).toBe(400);
    expect(code(again)).toBe('PAIRING_CODE_INVALID');
    expect((await deviceRow(pos1)).token_hash).toBe(sha256(token));

    // The computer is now that device; a computer without a token is none.
    const current = await call('get', '/api/devices/current', cashier, undefined, { pos: token });
    expect(current.status).toBe(200);
    expect(CurrentDeviceResponse.parse(current.body).device).toEqual(answer.device);
    const none = await call('get', '/api/devices/current', cashier);
    expect(CurrentDeviceResponse.parse(none.body)).toEqual({ device: null });

    const list = DeviceList.parse((await call('get', '/api/devices', owner)).body);
    const listed = list.find((d) => d.id === pos1);
    expect(listed).toMatchObject({ paired: true });
    expect(listed?.paired_at).not.toBeNull();
    expect(listed?.last_seen_at).not.toBeNull();
    expect(JSON.stringify(list)).not.toContain(sha256(token));
  });

  it('a shift needs the paired device of the request; a hand-made device id is no device', async () => {
    const body = { branch_id: branch, opening_float: '0' };
    const bare = await call('post', '/api/shifts', cashier, body, {
      key: `o03-it-bare-${STAMP}`,
    });
    expect(bare.status).toBe(409);
    expect(code(bare)).toBe('DEVICE_REQUIRED');

    // Forgery: the real id of the paired device, sent by hand without its token.
    const forged = await call('post', '/api/shifts', cashier, body, {
      key: `o03-it-forged-${STAMP}`,
      deviceId: pos1,
    });
    expect(forged.status).toBe(409);
    expect(code(forged)).toBe('DEVICE_REQUIRED');
    const forgedWrite = await call(
      'patch',
      `/api/devices/${pos2}`,
      owner,
      { name: 'Back till' },
      { deviceId: pos1, requestId: `o03-forged-${STAMP}` },
    );
    expect(forgedWrite.status, JSON.stringify(forgedWrite.body)).toBe(200);
    expect(await auditOf(`o03-forged-${STAMP}`)).toEqual([
      { action: 'device.updated', device_id: null, organization_id: org },
    ]);

    // A device id in the body that is not the computer's device.
    const mismatch = await call(
      'post',
      '/api/shifts',
      cashier,
      { ...body, device_id: pos2 },
      { key: `o03-it-mismatch-${STAMP}`, pos: token },
    );
    expect(mismatch.status).toBe(409);
    expect(code(mismatch)).toBe('DEVICE_MISMATCH');
    const { count } = await service
      .from('shifts')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', org);
    expect(count).toBe(0);

    const opened = await call('post', '/api/shifts', cashier, body, {
      key: `o03-it-shift-${STAMP}`,
      pos: token,
      requestId: `o03-shift-${STAMP}`,
    });
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const shift = Shift.parse(opened.body);
    const stored = await service.from('shifts').select('device_id').eq('id', shift.id).single();
    expect((stored.data as { device_id: string }).device_id).toBe(pos1);
    // The audit row of a request from a paired computer names its device.
    expect(await auditOf(`o03-shift-${STAMP}`)).toEqual([
      { action: 'shift.opened', device_id: pos1, organization_id: org },
    ]);

    // One open shift per device: the owner can't open one on the same computer.
    const second = await call('post', '/api/shifts', owner, body, {
      key: `o03-it-owner-${STAMP}`,
      pos: token,
    });
    expect(second.status).toBe(409);
    expect(code(second)).toBe('SHIFT_ALREADY_OPEN');
  });

  it("the sale carries the shift's device and its ETA receipt is prepared and accepted", async () => {
    const sold = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: tv, quantity: 1 }], expected_total: '1140.00' },
      { key: `o03-it-sale-${STAMP}`, pos: token },
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    const sale = Sale.parse(sold.body);
    const row = await service.from('sales').select('device_id').eq('id', sale.id).single();
    expect((row.data as { device_id: string }).device_id).toBe(pos1);

    const fiscal = async () => {
      const { data, error } = await service
        .from('fiscal_submissions')
        .select('status, device_id, eta_uuid, last_error')
        .eq('sale_id', sale.id)
        .single();
      if (error) throw new Error(error.message);
      return data;
    };
    // Prepared: the receipt has its UUID and QR text, for the POS of the sale. Never blocked.
    const prepared = await fiscal();
    expect(prepared.device_id).toBe(pos1);
    expect(prepared.eta_uuid).toMatch(/^[0-9a-f]{64}$/);
    expect(prepared.last_error).toBeNull();
    expect(sale.eta).toMatchObject({
      status: 'pending',
      uuid: prepared.eta_uuid,
      last_error_code: null,
    });
    expect(sale.eta?.qr_payload).toContain(prepared.eta_uuid);

    await drain();
    const done = await fiscal();
    expect(done.status).toBe('accepted');
    expect(fake.received.get(done.eta_uuid ?? '')).toBe(1);

    // A sale from a computer that sends no token still belongs to the shift's device.
    const plain = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: tv, quantity: 1 }], expected_total: '1140.00' },
      { key: `o03-it-sale-2-${STAMP}`, deviceId: pos2 },
    );
    expect(plain.status, JSON.stringify(plain.body)).toBe(201);
    const second = await service
      .from('sales')
      .select('device_id')
      .eq('id', Sale.parse(plain.body).id)
      .single();
    expect((second.data as { device_id: string }).device_id).toBe(pos1);
    await drain();
  });

  it('another shop can do nothing with the device, its code or its token', async () => {
    const fresh = await newCode(pos2);
    const typed = await call('post', '/api/devices/pair', otherOwner, { code: fresh.code });
    expect(typed.status).toBe(400);
    expect(code(typed)).toBe('PAIRING_CODE_INVALID');

    const stolen = await call('get', '/api/devices/current', otherOwner, undefined, {
      pos: token,
    });
    expect(stolen.status).toBe(403);
    expect(code(stolen)).toBe('DEVICE_REVOKED');

    for (const res of [
      await call('patch', `/api/devices/${pos1}`, otherOwner, { name: 'Taken over' }),
      await call('post', `/api/devices/${pos1}/active`, otherOwner, {
        active: false,
        reason: 'cross-shop',
      }),
      await call('post', `/api/devices/${pos1}/pairing-code`, otherOwner),
      await call('post', `/api/devices/${pos1}/unpair`, otherOwner),
    ]) {
      expect(res.status).toBe(404);
      expect(code(res)).toBe('DEVICE_NOT_FOUND');
    }
    // Aimed at our shop by header it is refused outright, before the device token is looked at.
    const aimed = await call('get', '/api/devices/current', otherOwner, undefined, {
      orgId: org,
      pos: token,
    });
    expect(aimed.status).toBe(403);
    expect(code(aimed)).toBe('SHOP_NOT_ALLOWED');
    const theirs = await call('get', '/api/devices', otherOwner);
    expect(DeviceList.parse(theirs.body)).toEqual([]);

    // Nothing of ours changed: the device is as it was and the code still pairs for us.
    expect(await deviceRow(pos1)).toMatchObject({
      name: 'POS-1',
      is_active: true,
      token_hash: sha256(token),
    });
    expect((await deviceRow(pos2)).pairing_code_hash).toBe(sha256(fresh.code));
  });

  it('a device with an open shift stays where it is; unpaired, its computer is refused next', async () => {
    const second = await call('post', '/api/branches', owner, { name: 'Second', code: 'S2' });
    // Starter has one branch: moving is tested against the open shift only when a branch exists.
    if (second.status === 201) {
      const moved = await call('patch', `/api/devices/${pos1}`, owner, {
        branch_id: (second.body as { id: string }).id,
      });
      expect(moved.status).toBe(409);
      expect(code(moved)).toBe('DEVICE_HAS_OPEN_SHIFT');
    }
    const off = await call('post', `/api/devices/${pos1}/active`, owner, {
      active: false,
      reason: 'Stolen',
    });
    expect(off.status).toBe(409);
    expect(code(off)).toBe('DEVICE_HAS_OPEN_SHIFT');
    const noReason = await call('post', `/api/devices/${pos2}/active`, owner, { active: false });
    expect(noReason.status).toBe(400);

    const before = await call('get', '/api/shifts/current', cashier, undefined, { pos: token });
    expect(before.status).toBe(200);
    const shiftId = (before.body as { shift: { id: string } }).shift.id;

    const unpaired = await call('post', `/api/devices/${pos1}/unpair`, owner);
    expect(unpaired.status, JSON.stringify(unpaired.body)).toBe(200);
    expect(unpaired.body).toEqual({ id: pos1, paired: false });
    expect((await deviceRow(pos1)).token_hash).toBeNull();

    // The very next request of that computer.
    const revoked = await call('get', '/api/shifts/current', cashier, undefined, { pos: token });
    expect(revoked.status).toBe(403);
    expect(code(revoked)).toBe('DEVICE_REVOKED');
    const sale = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: tv, quantity: 1 }], expected_total: '1140.00' },
      { key: `o03-it-sale-revoked-${STAMP}`, pos: token },
    );
    expect(sale.status).toBe(403);
    expect(code(sale)).toBe('DEVICE_REVOKED');
    // Once the browser forgot the token the session itself is fine.
    const without = await call('get', '/api/shifts/current', cashier);
    expect(without.status).toBe(200);

    // Pairing again gives a new token; the old one stays dead.
    const again = await newCode(pos1);
    const paired = await call('post', '/api/devices/pair', cashier, { code: again.code });
    expect(paired.status, JSON.stringify(paired.body)).toBe(200);
    const next = DevicePaired.parse(paired.body).device_token;
    expect(next).not.toBe(token);
    const old = await call('get', '/api/devices/current', cashier, undefined, { pos: token });
    expect(old.status).toBe(403);
    const fresh = await call('get', '/api/devices/current', cashier, undefined, { pos: next });
    expect(CurrentDeviceResponse.parse(fresh.body).device?.id).toBe(pos1);

    // The shift is closed; now the device can be turned off, which unpairs it.
    const closed = await call(
      'post',
      `/api/shifts/${shiftId}/close`,
      cashier,
      { counts: {}, difference_reason: 'O03 test' },
      { pos: next },
    );
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    const turnedOff = await call('post', `/api/devices/${pos1}/active`, owner, {
      active: false,
      reason: 'Stolen',
    });
    expect(turnedOff.status, JSON.stringify(turnedOff.body)).toBe(200);
    expect(turnedOff.body).toEqual({ id: pos1, is_active: false });
    const dead = await call('get', '/api/devices/current', cashier, undefined, { pos: next });
    expect(dead.status).toBe(403);
    expect(code(dead)).toBe('DEVICE_REVOKED');

    // Back on, inside the plan limit, and unpaired.
    const on = await call('post', `/api/devices/${pos1}/active`, owner, { active: true });
    expect(on.status, JSON.stringify(on.body)).toBe(200);
    expect(await deviceRow(pos1)).toMatchObject({ is_active: true, token_hash: null });
    const stillDead = await call('get', '/api/devices/current', cashier, undefined, { pos: next });
    expect(stillDead.status).toBe(403);
    token = next;
  });

  it('no audit row of the shop holds a pairing code, a device token or one of their hashes', async () => {
    const { data, error } = await service
      .from('audit_log')
      .select('action, reason, before, after')
      .eq('organization_id', org);
    if (error) throw new Error(error.message);
    const rows = data as { action: string }[];
    const actions = new Set(rows.map((row) => row.action));
    for (const action of [
      'device.created',
      'device.updated',
      'device.pairing_code_created',
      'device.paired',
      'device.unpaired',
      'device.deactivated',
      'device.reactivated',
    ]) {
      expect(actions).toContain(action);
    }
    const text = JSON.stringify(rows);
    for (const secret of [firstCode, token, sha256(firstCode), sha256(token)]) {
      expect(text).not.toContain(secret);
    }
  });

  it('the database itself refuses a hand-made device and counts failed pairings (no API in between)', async () => {
    // Anyone signed in can call PostgREST with the public key and their own JWT, so the rules
    // can't live in the API alone.
    const env = getEnv();
    const direct = async (fn: string, args: object, headers: Record<string, string> = {}) => {
      const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          apikey: env.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${cashier}`,
          'Content-Type': 'application/json',
          'x-org-id': org,
          ...headers,
        },
        body: JSON.stringify(args),
      });
      const body: unknown = await res.json().catch(() => null);
      return { status: res.status, body };
    };
    const message = (body: unknown) => String((body as { message?: unknown } | null)?.message);

    // POS-2 is paired through the API, so the cashier's browser holds its token.
    const made = await newCode(pos2);
    const paired = await call('post', '/api/devices/pair', cashier, { code: made.code });
    expect(paired.status, JSON.stringify(paired.body)).toBe(200);
    const held = DevicePaired.parse(paired.body).device_token;

    const shiftArgs = (key: string) => ({
      p_branch_id: branch,
      p_opening_float: '0',
      p_idempotency_key: `o03-direct-${key}-${STAMP}`,
    });
    // The real id of a paired device, written by hand: no device without the hash of its token.
    const forged = await direct('open_shift', shiftArgs('forged'), { 'x-device-id': pos2 });
    expect(forged.status).toBe(400);
    expect(message(forged.body)).toMatch(/^DEVICE_REQUIRED/);
    const wrongProof = await direct('open_shift', shiftArgs('wrong'), {
      'x-device-id': pos2,
      'x-device-token-hash': sha256('not-the-token'),
    });
    expect(message(wrongProof.body)).toMatch(/^DEVICE_REQUIRED/);
    // The hashes can't be read to forge one.
    const read = await direct('resolve_device', { p_token_hash: sha256('guess') });
    expect(read.body).toBeNull();
    const column = await fetch(`${env.SUPABASE_URL}/rest/v1/devices?select=token_hash`, {
      headers: {
        apikey: env.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${cashier}`,
        'x-org-id': org,
      },
    });
    expect(column.status).toBeGreaterThanOrEqual(400);
    const { count } = await service
      .from('shifts')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', org)
      .eq('status', 'open');
    expect(count).toBe(0);
    // The computer that holds the token is the device, with or without the API.
    const real = await direct('open_shift', shiftArgs('held'), {
      'x-device-id': pos2,
      'x-device-token-hash': sha256(held),
    });
    expect(real.status, JSON.stringify(real.body)).toBe(200);
    const shiftId = (real.body as { id: string }).id;
    const closed = await call(
      'post',
      `/api/shifts/${shiftId}/close`,
      cashier,
      { counts: {}, difference_reason: 'O03 test' },
      { pos: held },
    );
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);

    // Guessing codes straight at the database: every miss answers null and is counted, and
    // after five in a minute even the right code is not looked at.
    const target = await newCode(pos1);
    for (let attempt = 1; attempt <= 6; attempt += 1) {
      const guess = await direct('pair_device', {
        p_code_hash: sha256(`guess-${attempt}`),
        p_token_hash: sha256(`token-${attempt}`),
      });
      expect(guess.status).toBe(200);
      expect(guess.body).toBeNull();
    }
    const right = await direct('pair_device', {
      p_code_hash: sha256(target.code),
      p_token_hash: sha256('stolen-pairing'),
    });
    expect(right.status).toBe(200);
    expect(right.body).toBeNull();
    expect(await deviceRow(pos1)).toMatchObject({
      token_hash: null,
      pairing_code_hash: sha256(target.code),
    });
  });

  it('pairing attempts are limited to five a minute for each user', async () => {
    // The owner has typed no code yet in this run.
    for (let attempt = 1; attempt <= 5; attempt += 1) {
      const res = await call('post', '/api/devices/pair', owner, { code: 'ABCDEFGH' });
      expect(res.status).toBe(400);
      expect(code(res)).toBe('PAIRING_CODE_INVALID');
    }
    const sixth = await call('post', '/api/devices/pair', owner, { code: 'ABCDEFGH' });
    expect(sixth.status).toBe(429);
    expect(code(sixth)).toBe('TOO_MANY_REQUESTS');
    // Another user is not held back by it.
    const other = await call('post', '/api/devices/pair', otherOwner, { code: 'ABCDEFGH' });
    expect(other.status).toBe(400);
  });
});
