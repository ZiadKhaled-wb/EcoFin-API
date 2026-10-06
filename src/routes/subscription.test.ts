import { describe, it, expect, vi } from 'vitest';
import type { Request, Response, NextFunction } from 'express';
import request from 'supertest';
vi.mock('../middleware/auth', () => ({
  authenticate: (req: Request, _res: Response, next: NextFunction) => {
    req.auth = { userId: 'fake', accessToken: 'fake',email:'fake@example.com' };
    next();
  },
  dbFor: vi.fn(),
}));
vi.mock('../middleware/superAdmin', () => ({
  adminDbFor: vi.fn(),
  ignoreShopContext: (_req: Request, _res: Response, next: NextFunction) => next(),
  requireSuperAdmin: (_req: Request, _res: Response, next: NextFunction) => next(),
}));
const recordPayment = vi.hoisted(() => vi.fn());
vi.mock('../services/subscription.service', () => ({ recordPayment }));
import { createApp } from '../app';
const app = createApp({ env: { TRUST_PROXY: false, CORS_ALLOWED_ORIGINS: [] } });
describe('P05 payment route validation', () => {
  it.each([undefined, 'bad'])('requires UUID idempotency header %s', async (key) => {
    let req = request(app).post('/api/admin/shops/a0500000-0000-4000-8000-000000000001/payments');
    if (key) req = req.set('Idempotency-Key', key);
    const res = await req.send({
      amount: '500.25',
      period_start: '2026-10-01',
      period_end: '2026-10-31',
    });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(recordPayment).not.toHaveBeenCalled();
  });
});
