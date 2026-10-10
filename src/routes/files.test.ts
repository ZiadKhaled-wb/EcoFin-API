// /api/files with the real router, multer, validate() and the files service. Authentication and
// the request context are stubbed; the DB is the chainable Supabase mock; storage is mocked, so
// no test here reaches a bucket.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express, { type NextFunction, type Request, type Response } from 'express';
import request from 'supertest';
import { createSupabaseMock, type SupabaseMock } from '../test/supabase-mock';
import type { RequestContext } from '../middleware/requestContext';
import type { DbClient } from '../utils/supabase';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const EMP = '11111111-1111-4111-8111-111111111111';
const FILE_ID = '22222222-2222-4222-8222-222222222222';
const ENTITY = '33333333-3333-4333-8333-333333333333';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]);
const PDF = Buffer.from('%PDF-1.7 body');

const db: { current: SupabaseMock | null } = vi.hoisted(() => ({ current: null }));
const permsState = vi.hoisted(() => ({ keys: [] as string[] }));
const storage = vi.hoisted(() => ({
  putObject: vi.fn(),
  createSignedUrl: vi.fn(),
  removeObject: vi.fn(),
  listStoredObjects: vi.fn(),
}));

vi.mock('../services/storage.service', () => storage);
vi.mock('../services/permissions.service', () => ({
  getMyPermissions: () =>
    Promise.resolve({ keys: permsState.keys, branchIds: [], allBranches: true }),
}));
vi.mock('../middleware/auth', () => ({
  authenticate: (req: Request, _res: Response, next: NextFunction) => {
    req.auth = { userId: 'u1', email: null, accessToken: 't' };
    next();
  },
}));
vi.mock('../middleware/requestContext', () => ({
  loadRequestContext: (req: Request, _res: Response, next: NextFunction) => {
    const ctx: RequestContext = {
      userId: 'u1',
      employeeId: EMP,
      orgId: ORG,
      role: 'OWNER',
      defaultBranchId: null,
      branchIds: [],
      mustChangePassword: false,
      db: db.current as unknown as DbClient,
    };
    req.ctx = ctx;
    next();
  },
  getCtx: (req: Request) => {
    if (!req.ctx) throw new Error('no ctx');
    return req.ctx;
  },
}));

const { default: filesRoutes } = await import('./files');
const { errorHandler } = await import('../middleware/errorHandler');

const app = express();
app.use('/api/files', filesRoutes);
app.use(errorHandler);

beforeEach(() => {
  db.current = createSupabaseMock();
  permsState.keys = [];
  for (const m of Object.values(storage)) m.mockReset();
  storage.putObject.mockResolvedValue(undefined);
  storage.createSignedUrl.mockResolvedValue('https://signed.example/x');
});

const codeOf = (body: unknown): string | undefined =>
  (body as { error?: { code?: string } }).error?.code;

describe('POST /api/files', () => {
  it('413 FILE_TOO_LARGE for a file over FILE_MAX_BYTES, and nothing is stored', async () => {
    const big = Buffer.alloc(10485761, 1);
    const res = await request(app)
      .post('/api/files')
      .field('purpose', 'logo')
      .attach('file', big, { filename: 'big.png', contentType: 'image/png' });
    expect(res.status).toBe(413);
    expect(codeOf(res.body)).toBe('FILE_TOO_LARGE');
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('415 FILE_TYPE_NOT_ALLOWED for a PDF given to a photo purpose', async () => {
    permsState.keys = ['org.settings_manage'];
    const res = await request(app)
      .post('/api/files')
      .field('purpose', 'logo')
      .attach('file', PDF, { filename: 'logo.pdf', contentType: 'application/pdf' });
    expect(res.status).toBe(415);
    expect(codeOf(res.body)).toBe('FILE_TYPE_NOT_ALLOWED');
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('403 PERMISSION_DENIED without the upload permission for the purpose', async () => {
    permsState.keys = ['sale.create'];
    const res = await request(app)
      .post('/api/files')
      .field('purpose', 'logo')
      .attach('file', PNG, { filename: 'logo.png', contentType: 'image/png' });
    expect(res.status).toBe(403);
    expect(codeOf(res.body)).toBe('PERMISSION_DENIED');
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('404 when the entity id belongs to another shop, and nothing is stored', async () => {
    permsState.keys = ['org.settings_manage'];
    db.current!.queue({ data: [], error: null });
    const res = await request(app)
      .post('/api/files')
      .field('purpose', 'logo')
      .field('entityType', 'customer')
      .field('entityId', ENTITY)
      .attach('file', PNG, { filename: 'logo.png', contentType: 'image/png' });
    expect(res.status).toBe(404);
    expect(codeOf(res.body)).toBe('NOT_FOUND');
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('400 VALIDATION_FAILED when the purpose is not in the enum', async () => {
    const res = await request(app)
      .post('/api/files')
      .field('purpose', 'selfie')
      .attach('file', PNG, { filename: 'a.png', contentType: 'image/png' });
    expect(res.status).toBe(400);
    expect(codeOf(res.body)).toBe('VALIDATION_FAILED');
  });
});

describe('GET /api/files/:id/url', () => {
  it('404 FILE_NOT_FOUND for a file of another shop (same answer as a missing one)', async () => {
    db.current!.queue({ data: null, error: null });
    const res = await request(app).get(`/api/files/${FILE_ID}/url`);
    expect(res.status).toBe(404);
    expect(codeOf(res.body)).toBe('FILE_NOT_FOUND');
    expect(storage.createSignedUrl).not.toHaveBeenCalled();
  });

  it('403 for a customer_id link without customer.view_pii, and no link is made', async () => {
    db.current!.queue({
      data: { id: FILE_ID, purpose: 'customer_id', path: `${ORG}/customer_id/2026/10/a.jpg` },
      error: null,
    });
    permsState.keys = ['customer.create'];
    const res = await request(app).get(`/api/files/${FILE_ID}/url`);
    expect(res.status).toBe(403);
    expect(codeOf(res.body)).toBe('PERMISSION_DENIED');
    expect(storage.createSignedUrl).not.toHaveBeenCalled();
  });

  it('200 with a signed link and its expiry for a permitted employee', async () => {
    db.current!.queue({
      data: { id: FILE_ID, purpose: 'logo', path: `${ORG}/logo/2026/10/a.png` },
      error: null,
    });
    const res = await request(app).get(`/api/files/${FILE_ID}/url`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ url: 'https://signed.example/x' });
    expect(typeof res.body.expiresAt).toBe('string');
  });

  it('400 for a malformed file id', async () => {
    const res = await request(app).get('/api/files/not-a-uuid/url');
    expect(res.status).toBe(400);
  });
});

describe('GET /api/files', () => {
  it('404 when the record belongs to another shop', async () => {
    db.current!.queue({ data: [], error: null });
    const res = await request(app).get(`/api/files?entityType=customer&entityId=${ENTITY}`);
    expect(res.status).toBe(404);
    expect(codeOf(res.body)).toBe('NOT_FOUND');
  });

  it('400 when the entity id is not given with a type (strict query)', async () => {
    const res = await request(app).get('/api/files?entityType=customer');
    expect(res.status).toBe(400);
  });
});
