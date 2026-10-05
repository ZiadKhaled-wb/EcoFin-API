// storage.service: the service-role calls, with the Supabase client mocked.
import { describe, it, expect, vi, beforeEach } from 'vitest';

const storage = vi.hoisted(() => ({
  upload: vi.fn(),
  createSignedUrl: vi.fn(),
  remove: vi.fn(),
  list: vi.fn(),
}));

vi.mock('../utils/supabase', () => ({
  supabaseAdmin: {
    storage: { from: () => storage },
  },
}));

const { putObject, createSignedUrl, removeObject, listStoredObjects } =
  await import('./storage.service');

beforeEach(() => {
  storage.upload.mockReset();
  storage.createSignedUrl.mockReset();
  storage.remove.mockReset();
  storage.list.mockReset();
});

describe('putObject', () => {
  it('uploads to the private bucket and never overwrites', async () => {
    storage.upload.mockResolvedValue({ data: {}, error: null });
    await putObject('org/logo/2026/10/a.png', Buffer.from('x'), 'image/png');
    expect(storage.upload).toHaveBeenCalledWith('org/logo/2026/10/a.png', expect.any(Buffer), {
      contentType: 'image/png',
      upsert: false,
    });
  });
  it('turns a storage failure into a generic server error', async () => {
    storage.upload.mockResolvedValue({ data: null, error: { message: 'bucket secret detail' } });
    const err = await putObject('p', Buffer.from('x'), 'image/png').catch((e: unknown) => e);
    expect((err as { code: string }).code).toBe('INTERNAL');
    expect((err as Error).message).not.toContain('secret');
  });
});

describe('createSignedUrl', () => {
  it('returns the signed link for the requested lifetime', async () => {
    storage.createSignedUrl.mockResolvedValue({
      data: { signedUrl: 'https://s/x?token=t' },
      error: null,
    });
    await expect(createSignedUrl('org/p', 60)).resolves.toBe('https://s/x?token=t');
    expect(storage.createSignedUrl).toHaveBeenCalledWith('org/p', 60);
  });
  it('fails with a server error when no link comes back', async () => {
    storage.createSignedUrl.mockResolvedValue({ data: null, error: { message: 'nope' } });
    await expect(createSignedUrl('org/p', 60)).rejects.toMatchObject({ code: 'INTERNAL' });
  });
});

describe('removeObject', () => {
  it('removes one object and reports success', async () => {
    storage.remove.mockResolvedValue({ data: [], error: null });
    await expect(removeObject('org/p')).resolves.toBe(true);
    expect(storage.remove).toHaveBeenCalledWith(['org/p']);
  });
  it('reports failure without throwing, so the caller keeps its own error', async () => {
    storage.remove.mockResolvedValue({ data: null, error: { message: 'x' } });
    await expect(removeObject('org/p')).resolves.toBe(false);
  });
});

describe('listStoredObjects', () => {
  it('walks folders and returns every object with its creation time', async () => {
    const created = '2026-10-01T00:00:00.000Z';
    storage.list.mockImplementation((folder: string) => {
      if (folder === '')
        return Promise.resolve({ data: [{ name: 'org1', id: null }], error: null });
      if (folder === 'org1') {
        return Promise.resolve({
          data: [{ name: 'a.png', id: 'id-a', created_at: created }],
          error: null,
        });
      }
      return Promise.resolve({ data: [], error: null });
    });
    const objects = await listStoredObjects();
    expect(objects).toEqual([{ path: 'org1/a.png', createdAt: new Date(created) }]);
  });
  it('stops with a server error when a listing fails', async () => {
    storage.list.mockResolvedValue({ data: null, error: { message: 'x' } });
    await expect(listStoredObjects()).rejects.toMatchObject({ code: 'INTERNAL' });
  });
});
