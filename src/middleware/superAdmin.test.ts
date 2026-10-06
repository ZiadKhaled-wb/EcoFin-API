import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';
const mock = vi.hoisted(() => ({ db: vi.fn(), result: vi.fn() }));
vi.mock('../utils/supabase', () => ({ supabaseForRequest: mock.db }));
import { ignoreShopContext, requireSuperAdmin } from './superAdmin';
import { errorHandler } from './errorHandler';
beforeEach(() => {
  vi.clearAllMocks();
  const builder = { select: vi.fn(), eq: vi.fn(), maybeSingle: mock.result };
  builder.select.mockReturnValue(builder);
  builder.eq.mockReturnValue(builder);
  mock.db.mockReturnValue({ from: () => builder });
});
function app() {
  const a = express();
  a.get(
    '/',
    ignoreShopContext,
    (req, _res, next) => {
      req.auth = { userId: 'caller', email: null, accessToken: 'caller-jwt' };
      next();
    },
    requireSuperAdmin,
    (req, res) => res.json({ orgHeader: req.headers['x-org-id'] ?? null }),
  );
  a.use(errorHandler);
  return a;
}
describe('requireSuperAdmin', () => {
  it('rejects a shop owner', async () => {
    mock.result.mockResolvedValue({ data: null, error: null });
    const res = await request(app()).get('/');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('SUPER_ADMIN_REQUIRED');
  });
  it('uses only the caller JWT and ignores even invalid shop headers', async () => {
    mock.result.mockResolvedValue({ data: { is_active: true }, error: null });
    const res = await request(app()).get('/').set('x-org-id', 'invalid');
    expect(res.status).toBe(200);
    expect(res.body.orgHeader).toBeNull();
    expect(mock.db).toHaveBeenCalledWith('caller-jwt', undefined, expect.any(Object));
  });
});
