// TEST-1 (EC-128): F14 files across shops with REAL shop B data (a shop B customer and a file shop
// B uploaded for it), through the API and straight against the database with shop A's own token.
// The cross-shop cases in src/test/cross-shop/cases.ts use an id that doesn't exist; these prove a
// real record of another shop reads exactly like a missing one. Skipped unless RUN_INTEGRATION=1
// (env: see src/routes/auth.integration.test.ts).
import { describe, it, expect, beforeAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse, FileResponse } from '@ziadkhaled-wb/contracts';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SEED_PASSWORD = 'LocalDev-Only-2026!';
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const SHOP_TWO = 'd1000000-0000-0000-0000-000000000002';
const NO_SUCH_ID = '00000000-0000-4000-8000-0000000c0de1';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(9)]);
const STAMP = Date.now();

// 198.18.5.0/24; the other integration files use other ranges.
let ipCounter = 0;
const nextIp = () => `198.18.5.${(ipCounter++ % 250) + 1}`;

describe.skipIf(!RUN)('TEST-1: F14 files across shops with real shop B data', () => {
  let app: ReturnType<typeof import('../app').createApp>;
  let service: SupabaseClient;
  let asA: SupabaseClient; // shop A's owner, straight to PostgREST / Storage with their own JWT
  let tokenA: string;
  let customerB: string;
  let fileB: string;
  let pathB: string;

  async function login(identifier: string): Promise<string> {
    const res = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier, password: SEED_PASSWORD });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body).accessToken;
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const filesFor = async (entityId: string) => {
    const { count, error } = await service
      .from('files')
      .select('id', { count: 'exact', head: true })
      .eq('entity_id', entityId);
    expect(error).toBeNull();
    return count ?? 0;
  };

  beforeAll(async () => {
    const { createApp } = await import('../app');
    app = createApp();
    const env = (await import('../utils/env')).getEnv();
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Shop B: a customer, and a file its owner uploads for that customer through the API.
    const { data: customer, error } = await service
      .from('customers')
      .insert({ organization_id: SHOP_TWO, full_name: `TEST-1 customer B ${STAMP}` })
      .select('id')
      .single();
    expect(error).toBeNull();
    customerB = customer!.id as string;
    const tokenB = await login('owner.two@ecotech.test');
    const upload = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${tokenB}`)
      .field('purpose', 'customer_id')
      .field('entityType', 'customer')
      .field('entityId', customerB)
      .attach('file', PNG, { filename: 'id.png', contentType: 'image/png' });
    expect(upload.status, JSON.stringify(upload.body)).toBe(201);
    fileB = FileResponse.parse(upload.body).id;
    const { data: row } = await service.from('files').select('path').eq('id', fileB).single();
    pathB = row!.path as string;
    expect(pathB.startsWith(`${SHOP_TWO}/`)).toBe(true);

    tokenA = await login('owner.one@ecotech.test');
    asA = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${tokenA}` } },
    });
  });

  describe('through the API (owner A holds every permission)', () => {
    it("shop B's real file id reads exactly like a missing one: 404 FILE_NOT_FOUND", async () => {
      const real = await request(app)
        .get(`/api/files/${fileB}/url`)
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`);
      const missing = await request(app)
        .get(`/api/files/${NO_SUCH_ID}/url`)
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`);
      expect(real.status).toBe(404);
      expect(code(real)).toBe('FILE_NOT_FOUND');
      expect([missing.status, code(missing)]).toEqual([real.status, code(real)]);
      expect(JSON.stringify(real.body)).not.toContain(pathB);
    });

    it("listing the files of shop B's real customer reads like a missing record (404), nothing listed", async () => {
      const real = await request(app)
        .get('/api/files')
        .query({ entityType: 'customer', entityId: customerB })
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`);
      const missing = await request(app)
        .get('/api/files')
        .query({ entityType: 'customer', entityId: NO_SUCH_ID })
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`);
      expect(real.status).toBe(404);
      expect([missing.status, code(missing)]).toEqual([real.status, code(real)]);
      expect(JSON.stringify(real.body)).not.toContain(fileB);
    });

    it("uploading a file for shop B's real customer is refused (404) and stores nothing", async () => {
      const before = await filesFor(customerB);
      const res = await request(app)
        .post('/api/files')
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`)
        .field('purpose', 'customer_id')
        .field('entityType', 'customer')
        .field('entityId', customerB)
        .attach('file', PNG, { filename: 'id.png', contentType: 'image/png' });
      expect(res.status).toBe(404);
      expect(await filesFor(customerB)).toBe(before);
    });

    it('aiming the request at shop B is refused before anything is read (403 SHOP_NOT_ALLOWED)', async () => {
      const res = await request(app)
        .get(`/api/files/${fileB}/url`)
        .set('X-Forwarded-For', nextIp())
        .set('Authorization', `Bearer ${tokenA}`)
        .set('x-org-id', SHOP_TWO);
      expect(res.status).toBe(403);
      expect(code(res)).toBe('SHOP_NOT_ALLOWED');
    });
  });

  describe("straight against the database with shop A's own token", () => {
    it("PostgREST shows none of shop B's rows: the file, the customer, any row of shop B", async () => {
      const file = await asA.from('files').select('id').eq('id', fileB);
      const customer = await asA.from('customers').select('id').eq('id', customerB);
      const anyB = await asA.from('files').select('id').eq('organization_id', SHOP_TWO);
      expect(file.error).toBeNull();
      expect(file.data).toEqual([]);
      expect(customer.data).toEqual([]);
      expect(anyB.data).toEqual([]);
      // and the token does work for its own shop (the empty results are not an auth failure)
      const own = await asA.from('organizations').select('id').eq('id', SHOP_ONE);
      expect(own.data).toEqual([{ id: SHOP_ONE }]);
    });

    it("Storage refuses shop B's object, by path, for download and for a signed link", async () => {
      const download = await asA.storage.from('tenant-files').download(pathB);
      expect(download.data).toBeNull();
      expect(download.error).not.toBeNull();
      const signed = await asA.storage.from('tenant-files').createSignedUrl(pathB, 60);
      expect(signed.data).toBeNull();
    });

    it('direct table writes are refused (no INSERT/UPDATE grant for authenticated)', async () => {
      const insert = await asA
        .from('customers')
        .insert({ organization_id: SHOP_ONE, full_name: 'x' });
      const update = await asA.from('files').update({ original_name: 'x' }).eq('id', fileB);
      expect(insert.error).not.toBeNull();
      expect(update.error).not.toBeNull();
      const { data } = await service.from('files').select('original_name').eq('id', fileB).single();
      expect(data!.original_name).toBe('id.png');
    });

    it("register_file with a path in shop B's folder is refused (FILE_PATH_INVALID), no row", async () => {
      const id = crypto.randomUUID();
      const { error } = await asA.rpc('register_file', {
        p_id: id,
        p_path: `${SHOP_TWO}/logo/2026/10/${id}.png`,
        p_original_name: 'x.png',
        p_mime: 'image/png',
        p_size_bytes: 10,
        p_sha256: null,
        p_purpose: 'logo',
        p_entity_type: null,
        p_entity_id: null,
      });
      expect(error?.message).toMatch(/FILE_PATH_INVALID/);
      const { count } = await service
        .from('files')
        .select('id', { count: 'exact', head: true })
        .eq('id', id);
      expect(count).toBe(0);
    });

    // KNOWN BUG (TEST-1): register_file doesn't check that p_entity_id belongs to the caller's shop
    // (supabase/migrations/20261005120000_f14_register_file.sql:53-56). The API checks it (test
    // above), a direct call with the user's token does not. `.fails` until the function is fixed.
    it.fails(
      "register_file pointing at shop B's customer (entity_id) is refused, no row",
      async () => {
        const id = crypto.randomUUID();
        const { error } = await asA.rpc('register_file', {
          p_id: id,
          p_path: `${SHOP_ONE}/customer_id/2026/10/${id}.png`,
          p_original_name: 'x.png',
          p_mime: 'image/png',
          p_size_bytes: 10,
          p_sha256: null,
          p_purpose: 'customer_id',
          p_entity_type: 'customer',
          p_entity_id: customerB,
        });
        expect(error).not.toBeNull();
      },
    );
  });
});
