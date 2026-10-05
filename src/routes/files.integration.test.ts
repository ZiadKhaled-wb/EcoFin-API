// F14 files over HTTP against local Supabase: the real app (in-process, supertest), GoTrue, Postgres
// and the private bucket tenant-files. Skipped unless RUN_INTEGRATION=1 (env: see
// src/routes/auth.integration.test.ts). Not run in CI here until the local stack is up.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import { createHash } from 'node:crypto';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  FileResponse,
  FileUrlResponse,
} from '@ziadkhaled-wb/contracts';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SEED_PASSWORD = 'LocalDev-Only-2026!';
const OWNER_A = 'owner.one@ecotech.test';
const OWNER_B = 'owner.two@ecotech.test';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]);

// 198.18.4.0/24; the other integration files use other ranges.
let ipCounter = 0;
const nextIp = () => `198.18.4.${(ipCounter++ % 250) + 1}`;

describe.skipIf(!RUN)('F14 files over HTTP (local Supabase)', () => {
  let app: ReturnType<typeof import('../app').createApp>;
  let service: SupabaseClient;
  let fileId: string;
  let tokenA: string;
  let tokenB: string;

  async function login(identifier: string): Promise<string> {
    const res = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier, password: SEED_PASSWORD });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body).accessToken;
  }

  beforeAll(async () => {
    // A two-second link, read when the first request needs the env (fresh module registry per file).
    process.env['FILE_URL_TTL_SECONDS'] = '2';
    const { createApp } = await import('../app');
    app = createApp();
    const env = (await import('../utils/env')).getEnv();
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    tokenA = await login(OWNER_A);
    tokenB = await login(OWNER_B);
  });

  afterAll(() => {
    delete process.env['FILE_URL_TTL_SECONDS'];
  });

  it('uploads a photo (201), its metadata matches the bytes, and the bucket holds the object', async () => {
    const res = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${tokenA}`)
      .field('purpose', 'logo')
      .attach('file', PNG, { filename: 'logo.png', contentType: 'image/png' });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const file = FileResponse.parse(res.body);
    fileId = file.id;
    expect(file.sizeBytes).toBe(PNG.length);

    // The same sha256 the server computed, read back from the row and from storage.
    const { data: row, error } = await service
      .from('files')
      .select('path, sha256')
      .eq('id', fileId)
      .single();
    expect(error).toBeNull();
    const { data: blob, error: dlError } = await service.storage
      .from('tenant-files')
      .download(row!.path);
    expect(dlError).toBeNull();
    const stored = Buffer.from(await blob!.arrayBuffer());
    expect(createHash('sha256').update(stored).digest('hex')).toBe(row!.sha256);
  });

  it('a signed link downloads the file with 200, then fails once it has expired', async () => {
    const res = await request(app)
      .get(`/api/files/${fileId}/url`)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    const link = FileUrlResponse.parse(res.body);

    const fresh = await fetch(link.url);
    expect(fresh.status).toBe(200);

    await new Promise((resolve) => setTimeout(resolve, 3000));
    const expired = await fetch(link.url);
    expect(expired.status).not.toBe(200);
  });

  it("another shop's user: the file id is not found, for the record and for its link", async () => {
    const url = await request(app)
      .get(`/api/files/${fileId}/url`)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${tokenB}`);
    expect(url.status).toBe(404);
    expect(ErrorResponse.parse(url.body).error.code).toBe('FILE_NOT_FOUND');

    const list = await request(app)
      .get('/api/files')
      .query({ entityType: 'customer', entityId: '00000000-0000-4000-8000-00000000f14f' })
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${tokenB}`);
    expect(list.status).toBe(404);
  });
});
