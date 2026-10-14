import { describe, it, expect } from 'vitest';
import { ShiftForceCloseBody } from './shifts.js';
import { errorCodeHttpStatus } from './errors.js';
describe('EC147 force close contract', () => {
  it('accepts decimal counted cash and a trimmed required reason', () => {
    expect(ShiftForceCloseBody.parse({ counted_cash: '90.00', reason: ' Lost POS ' })).toEqual({
      counted_cash: '90.00',
      reason: 'Lost POS',
    });
    for (const counted_cash of ['-1', '1.001', 'wrong'])
      expect(ShiftForceCloseBody.safeParse({ counted_cash, reason: 'Lost POS' }).success).toBe(
        false,
      );
    for (const reason of ['', '  ', 'no'])
      expect(ShiftForceCloseBody.safeParse({ counted_cash: '0', reason }).success).toBe(false);
    expect(
      ShiftForceCloseBody.safeParse({
        counted_cash: '0',
        reason: 'Lost POS',
        organization_id: 'fake',
      }).success,
    ).toBe(false);
  });
  it('maps revoked and mismatch to their specified statuses', () => {
    expect(errorCodeHttpStatus.DEVICE_REVOKED).toBe(403);
    expect(errorCodeHttpStatus.DEVICE_MISMATCH).toBe(409);
  });
});
