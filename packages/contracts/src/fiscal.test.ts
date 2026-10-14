import { describe, expect, it } from 'vitest';
import { ERROR_CODES, errorCodeHttpStatus } from './errors.js';
import {
  FiscalAssignDeviceBody,
  FiscalDiagnosis,
  FiscalListQuery,
  FiscalRetryManyBody,
  FiscalSituation,
} from './fiscal.js';

const id = '8f0f3d1e-0f5a-4c64-9b0a-6a6a3a1b2c3d';

describe('T03 fiscal contracts', () => {
  it('has the six situations', () => {
    expect(FiscalSituation.options).toEqual([
      'waiting',
      'accepted',
      'cancelled',
      'blocked',
      'send_failed',
      'rejected',
    ]);
  });

  it('parses the list query with defaults and refuses a bad range or an unknown key', () => {
    expect(FiscalListQuery.parse({})).toMatchObject({ limit: 50, offset: 0 });
    expect(FiscalListQuery.parse({ situation: 'problem', limit: '100' }).limit).toBe(100);
    expect(FiscalListQuery.safeParse({ limit: '101' }).success).toBe(false);
    expect(FiscalListQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success).toBe(false);
    expect(FiscalListQuery.safeParse({ situation: 'other' }).success).toBe(false);
    expect(FiscalListQuery.safeParse({ organization_id: id }).success).toBe(false);
  });

  it('retry-many takes 1 to 200 ids', () => {
    expect(FiscalRetryManyBody.safeParse({ ids: [] }).success).toBe(false);
    expect(FiscalRetryManyBody.safeParse({ ids: Array(200).fill(id) }).success).toBe(true);
    expect(FiscalRetryManyBody.safeParse({ ids: Array(201).fill(id) }).success).toBe(false);
  });

  it('assign-device needs a device id and nothing else', () => {
    expect(FiscalAssignDeviceBody.safeParse({ device_id: id }).success).toBe(true);
    expect(FiscalAssignDeviceBody.safeParse({ device_id: id, branch_id: id }).success).toBe(false);
  });

  it('parses a diagnosis with a not-fixable buyer problem', () => {
    const parsed = FiscalDiagnosis.parse({
      situation: 'blocked',
      action: 'retry',
      ready: false,
      correction_queued: false,
      deadline_at: null,
      deadline_state: 'ok',
      problems: [{ code: 'BUYER_MISSING', fixable: false, fix: null }],
    });
    expect(parsed.problems[0]?.fixable).toBe(false);
  });

  it('has the T03 error codes with their statuses', () => {
    for (const code of [
      'USE_CORRECTION',
      'NOT_REJECTED',
      'CORRECTION_QUEUED',
      'CORRECTION_CONFLICT',
      'NOT_BLOCKED_NO_DEVICE',
      'NOT_SUBMITTED',
    ] as const) {
      expect(ERROR_CODES).toContain(code);
      expect(errorCodeHttpStatus[code]).toBe(409);
    }
    expect(errorCodeHttpStatus.DEVICE_INVALID_FOR_RECEIPT).toBe(400);
  });
});
