import { describe, it, expect } from 'vitest';
import { errorCodeHttpStatus } from '@ecotech/contracts';
import { AppError, BadRequest, mapDbError } from './errors';

describe('AppError', () => {
  it('defaults the status to the contract status for its code', () => {
    expect(new AppError('x', 'OUT_OF_STOCK').statusCode).toBe(409);
    expect(BadRequest('x').statusCode).toBe(400);
  });
});

describe('mapDbError', () => {
  it('maps a message starting with a contract code, with a safe message', () => {
    const mapped = mapDbError({
      message: 'OUT_OF_STOCK: product 8f1c needs 3, has 1',
      details: 'secret detail',
      hint: 'secret hint',
    });
    expect(mapped?.code).toBe('OUT_OF_STOCK');
    expect(mapped?.statusCode).toBe(errorCodeHttpStatus.OUT_OF_STOCK);
    expect(mapped?.message).not.toMatch(/product|secret|8f1c/);
  });

  it('maps a bare code', () => {
    expect(mapDbError({ message: 'PERMISSION_DENIED' })?.statusCode).toBe(403);
    expect(mapDbError({ message: 'DAY_CLOSED: 2026-10-01' })?.code).toBe('DAY_CLOSED');
  });

  it('ignores anything else', () => {
    expect(mapDbError(new Error('connection refused'))).toBeUndefined();
    expect(mapDbError({ message: 'NOT_A_CODE: x' })).toBeUndefined();
    expect(mapDbError({ message: 'OUT_OF_STOCKS: x' })).toBeUndefined();
    expect(mapDbError({ message: 'permission denied for table x' })).toBeUndefined();
    expect(mapDbError('OUT_OF_STOCK')).toBeUndefined();
    expect(mapDbError(null)).toBeUndefined();
  });
});
