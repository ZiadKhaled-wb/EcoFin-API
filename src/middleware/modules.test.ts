import { describe, it, expect, vi } from 'vitest';
import type { Request, Response } from 'express';
import { requireModule } from './modules';
describe('P05 module middleware', () => {
  it.each([false, true])('module available = %s', async (allowed) => {
    const rpc = vi.fn().mockResolvedValue({
      data: null,
      error: allowed ? null : { message: 'MODULE_NOT_IN_PLAN: installments' },
    });
    const req = { ctx: { db: { rpc } } } as unknown as Request;
    const next = vi.fn();
    requireModule('installments')(req, {} as Response, next);
    await vi.waitFor(() => expect(next).toHaveBeenCalled());
    expect(rpc).toHaveBeenCalledWith('require_module', { p_module: 'installments' });
    if (allowed) expect(next).toHaveBeenCalledWith();
    else
      expect(next.mock.calls[0]?.[0]).toMatchObject({
        code: 'MODULE_NOT_IN_PLAN',
        statusCode: 403,
      });
  });
});
