import { readFileSync } from 'node:fs';
import { describe, it, expect, vi, beforeEach } from 'vitest';

const db = vi.hoisted(() => ({ query: vi.fn(), signal: undefined as AbortSignal | undefined }));

vi.mock('../utils/supabase', () => ({
  supabaseAdmin: {
    from: () => ({
      select: () => ({
        limit: () => ({
          abortSignal: (signal: AbortSignal) => {
            db.signal = signal;
            return db.query(signal);
          },
        }),
      }),
    }),
  },
}));

import { API_VERSION, checkDb } from './health.controller';

describe('API_VERSION', () => {
  it('equals the version in package.json', () => {
    const pkg = JSON.parse(
      readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
    ) as {
      version: string;
    };
    expect(API_VERSION).toBe(pkg.version);
  });
});

describe('checkDb', () => {
  beforeEach(() => {
    db.query.mockReset();
    db.signal = undefined;
  });

  it('is true when the query answers', async () => {
    db.query.mockResolvedValue({ data: [], error: null });
    await expect(checkDb()).resolves.toBe(true);
  });

  it('is false when the query returns an error', async () => {
    db.query.mockResolvedValue({ data: null, error: { message: 'boom' } });
    await expect(checkDb()).resolves.toBe(false);
  });

  it('is false when the query throws', async () => {
    db.query.mockRejectedValue(new Error('ECONNREFUSED'));
    await expect(checkDb()).resolves.toBe(false);
  });

  it('aborts the query after the timeout and reports down', async () => {
    // Like supabase-js: an aborted request resolves with an error object.
    db.query.mockImplementation(
      (signal: AbortSignal) =>
        new Promise((resolve) => {
          signal.addEventListener('abort', () =>
            resolve({ data: null, error: { message: 'AbortError: timed out' } }),
          );
        }),
    );
    await expect(checkDb(20)).resolves.toBe(false);
    expect(db.signal?.aborted).toBe(true);
  });
});
