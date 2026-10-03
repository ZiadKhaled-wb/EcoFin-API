import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const db = vi.hoisted(() => ({ query: vi.fn() }));

vi.mock('../utils/supabase', () => ({
  supabaseAdmin: { from: () => ({ select: () => ({ limit: () => db.query() }) }) },
}));

import { checkDb } from './health.controller';

describe('checkDb', () => {
  beforeEach(() => {
    db.query.mockReset();
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('is true when the query answers', async () => {
    db.query.mockResolvedValue({ data: [], error: null });
    await expect(checkDb()).resolves.toBe(true);
  });

  it('is false when the query returns an error', async () => {
    db.query.mockResolvedValue({ data: null, error: { message: 'boom' } });
    await expect(checkDb()).resolves.toBe(false);
  });

  it('is false when the query never answers (timeout)', async () => {
    db.query.mockReturnValue(new Promise(() => undefined));
    const result = checkDb(2000);
    await vi.advanceTimersByTimeAsync(2000);
    await expect(result).resolves.toBe(false);
  });
});
