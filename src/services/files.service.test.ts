// F14 files service: the order of checks, the storage calls and the metadata write, with the
// chainable Supabase mock and the storage module mocked (no network, no real bucket).
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSupabaseMock, type SupabaseMock } from '../test/supabase-mock';
import type { RequestContext } from '../middleware/requestContext';
import type { DbClient } from '../utils/supabase';
import { AppError } from '../utils/errors';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OTHER_ORG = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const EMP = '11111111-1111-4111-8111-111111111111';
const FILE_ID = '22222222-2222-4222-8222-222222222222';
const ENTITY = '33333333-3333-4333-8333-333333333333';
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]);
const PDF = Buffer.from('%PDF-1.7 body');
const SETTINGS = { maxBytes: 10485760, urlTtlSeconds: 60 };

const storageMock = vi.hoisted(() => ({
  putObject: vi.fn(),
  createSignedUrl: vi.fn(),
  removeObject: vi.fn(),
  listStoredObjects: vi.fn(),
}));
vi.mock('./storage.service', () => storageMock);

const perms = vi.hoisted(() => ({ keys: [] as string[] }));
vi.mock('./permissions.service', () => ({
  getMyPermissions: () => Promise.resolve({ keys: perms.keys, branchIds: [], allBranches: true }),
}));

const { uploadFile, getFileUrl, listFiles } = await import('./files.service');

let db: SupabaseMock;
let ctx: RequestContext;

beforeEach(() => {
  db = createSupabaseMock();
  ctx = {
    userId: 'u1',
    employeeId: EMP,
    orgId: ORG,
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  perms.keys = [];
  for (const m of Object.values(storageMock)) m.mockReset();
  storageMock.putObject.mockResolvedValue(undefined);
  storageMock.removeObject.mockResolvedValue(true);
  storageMock.createSignedUrl.mockResolvedValue('https://signed.example/x?t=1');
});

const codeOf = async (p: Promise<unknown>): Promise<string> => {
  try {
    await p;
  } catch (err) {
    return err instanceof AppError ? err.code : 'other';
  }
  return 'none';
};

const upload = (
  over: Partial<{
    purpose: string;
    entityType: string;
    entityId: string;
    file: unknown;
    settings: typeof SETTINGS;
  }> = {},
) =>
  uploadFile(
    ctx,
    (over.file as { buffer: Buffer; originalname: string } | undefined) ?? {
      buffer: PNG,
      originalname: 'logo.png',
    },
    {
      purpose: (over.purpose ?? 'logo') as 'logo',
      ...(over.entityType !== undefined ? { entityType: over.entityType } : {}),
      ...(over.entityId !== undefined ? { entityId: over.entityId } : {}),
    },
    over.settings ?? SETTINGS,
  );

describe('uploadFile', () => {
  it('refuses a purpose the caller has no permission for, before anything is stored', async () => {
    perms.keys = ['sale.create'];
    expect(await codeOf(upload({ purpose: 'logo' }))).toBe('PERMISSION_DENIED');
    expect(storageMock.putObject).not.toHaveBeenCalled();
  });

  it('refuses a file over the size limit with FILE_TOO_LARGE, before storage', async () => {
    perms.keys = ['org.settings_manage'];
    expect(await codeOf(upload({ settings: { ...SETTINGS, maxBytes: 4 } }))).toBe('FILE_TOO_LARGE');
    expect(storageMock.putObject).not.toHaveBeenCalled();
  });

  it('refuses a type the purpose does not allow, from the bytes, not the name', async () => {
    perms.keys = ['org.settings_manage'];
    expect(await codeOf(upload({ file: { buffer: PDF, originalname: 'logo.png' } }))).toBe(
      'FILE_TYPE_NOT_ALLOWED',
    );
    expect(storageMock.putObject).not.toHaveBeenCalled();
  });

  it('refuses a file part that is missing', async () => {
    perms.keys = ['org.settings_manage'];
    expect(await codeOf(uploadFile(ctx, undefined, { purpose: 'logo' }, SETTINGS))).toBe(
      'VALIDATION_FAILED',
    );
  });

  it('refuses an entity type it does not know', async () => {
    perms.keys = ['org.settings_manage'];
    expect(await codeOf(upload({ entityType: 'mystery', entityId: ENTITY }))).toBe(
      'VALIDATION_FAILED',
    );
    expect(storageMock.putObject).not.toHaveBeenCalled();
  });

  it('refuses an entity id from another shop as not found, before storage', async () => {
    perms.keys = ['org.settings_manage'];
    db.queue({ data: [], error: null }); // assertSameOrg: no row in this shop
    expect(await codeOf(upload({ entityType: 'customer', entityId: ENTITY }))).toBe('NOT_FOUND');
    expect(storageMock.putObject).not.toHaveBeenCalled();
  });

  it('stores the object under <org>/<purpose>/<yyyy>/<mm>/<uuid>.<ext> and records its metadata', async () => {
    perms.keys = ['org.settings_manage'];
    db.queue(
      { data: FILE_ID, error: null }, // register_file returns the new id
      {
        data: {
          id: FILE_ID,
          purpose: 'logo',
          mime: 'image/png',
          size_bytes: PNG.length,
          original_name: 'logo.png',
          entity_type: null,
          entity_id: null,
          created_at: '2026-10-05T12:00:00.123456+00:00',
        },
        error: null,
      },
    );
    const out = await upload();
    const path = storageMock.putObject.mock.calls[0]?.[0] as string;
    expect(path).toMatch(new RegExp(`^${ORG}/logo/\\d{4}/\\d{2}/[0-9a-f-]{36}\\.png$`));
    expect(storageMock.putObject).toHaveBeenCalledWith(path, PNG, 'image/png');
    expect(out).toMatchObject({
      purpose: 'logo',
      mime: 'image/png',
      sizeBytes: PNG.length,
      originalName: 'logo.png',
      entityType: null,
      entityId: null,
    });
    expect(out.createdAt).toBe('2026-10-05T12:00:00.123Z');
  });

  it('removes the stored object when the metadata write fails, and returns the mapped error', async () => {
    perms.keys = ['org.settings_manage'];
    db.queue({
      data: null,
      error: { message: 'FILE_PATH_INVALID: path does not start with the shop id' },
    });
    expect(await codeOf(upload())).toBe('FILE_PATH_INVALID');
    expect(storageMock.removeObject).toHaveBeenCalledTimes(1);
    expect(storageMock.removeObject.mock.calls[0]?.[0]).toBe(
      storageMock.putObject.mock.calls[0]?.[0],
    );
  });

  it('never writes metadata when the object could not be stored', async () => {
    perms.keys = ['org.settings_manage'];
    storageMock.putObject.mockRejectedValue(new AppError('Request failed.', 'INTERNAL', 500));
    expect(await codeOf(upload())).toBe('INTERNAL');
    expect(db.rpc).not.toHaveBeenCalled();
    expect(storageMock.removeObject).not.toHaveBeenCalled();
  });
});

describe('getFileUrl', () => {
  it('answers not found for a file that is not in this shop (RLS hides it)', async () => {
    db.queue({ data: null, error: null });
    expect(await codeOf(getFileUrl(ctx, FILE_ID, SETTINGS))).toBe('FILE_NOT_FOUND');
    expect(storageMock.createSignedUrl).not.toHaveBeenCalled();
  });

  it('refuses a customer_id link without customer.view_pii, with no link made', async () => {
    perms.keys = ['customer.create'];
    db.queue({
      data: { id: FILE_ID, purpose: 'customer_id', path: `${ORG}/customer_id/2026/10/a.jpg` },
      error: null,
    });
    expect(await codeOf(getFileUrl(ctx, FILE_ID, SETTINGS))).toBe('PERMISSION_DENIED');
    expect(storageMock.createSignedUrl).not.toHaveBeenCalled();
  });

  it('gives a link to an employee for a purpose any employee may read', async () => {
    db.queue({
      data: { id: FILE_ID, purpose: 'logo', path: `${ORG}/logo/2026/10/a.png` },
      error: null,
    });
    const out = await getFileUrl(ctx, FILE_ID, SETTINGS);
    expect(out.url).toBe('https://signed.example/x?t=1');
    expect(storageMock.createSignedUrl).toHaveBeenCalledWith(`${ORG}/logo/2026/10/a.png`, 60);
    const expires = Date.parse(out.expiresAt) - Date.now();
    expect(expires).toBeGreaterThan(55_000);
    expect(expires).toBeLessThanOrEqual(60_000);
  });

  it('refuses a stored path under another shop, as not found, with no link made', async () => {
    db.queue({
      data: { id: FILE_ID, purpose: 'logo', path: `${OTHER_ORG}/logo/2026/10/a.png` },
      error: null,
    });
    expect(await codeOf(getFileUrl(ctx, FILE_ID, SETTINGS))).toBe('NOT_FOUND');
    expect(storageMock.createSignedUrl).not.toHaveBeenCalled();
  });
});

describe('listFiles', () => {
  const query = { entityType: 'customer', entityId: ENTITY };
  const row = (purpose: string, id: string) => ({
    id,
    purpose,
    mime: 'image/jpeg',
    size_bytes: 10,
    original_name: null,
    entity_type: 'customer',
    entity_id: ENTITY,
    created_at: '2026-10-05T12:00:00Z',
  });

  it('answers not found for a record of another shop', async () => {
    db.queue({ data: [], error: null });
    expect(await codeOf(listFiles(ctx, query))).toBe('NOT_FOUND');
  });

  it('lists only the purposes the caller may read, and never a URL', async () => {
    perms.keys = [];
    db.queue(
      { data: [{ id: ENTITY }], error: null },
      {
        data: [row('survey_photo', FILE_ID), row('logo', '44444444-4444-4444-8444-444444444444')],
        error: null,
      },
    );
    const out = await listFiles(ctx, query);
    expect(out.items.map((i) => i.purpose)).toEqual(['logo']);
    expect(JSON.stringify(out)).not.toContain('url');
  });

  it('refuses an unknown entity type', async () => {
    expect(await codeOf(listFiles(ctx, { entityType: 'mystery', entityId: ENTITY }))).toBe(
      'VALIDATION_FAILED',
    );
  });
});
