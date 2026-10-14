import { describe, expect, it } from 'vitest';
import type { Job } from '../jobs/types';
import { createLogger } from '../utils/logger';
import { errorCodeHttpStatus } from '@ziadkhaled-wb/contracts';
import { mapDbError } from '../utils/errors';
import { buildReceipt } from './build-receipt';
import {
  buildCorrection,
  correctionNote,
  originalEtaError,
  parseEtaError,
  sameReceiptIgnoringChain,
} from './correct';
import { fixForProperty } from '../services/fiscal.service';
import { etaJobHandlers } from './jobs';
import { toJson } from './serialize';
import type { CorrectionSource, EtaStore, PendingRow } from './store';

const ORG = '11111111-1111-4111-8111-111111111111';
const FISCAL = '44444444-4444-4444-8444-444444444444';
const PREVIOUS = 'a'.repeat(64);
const HOSTS = {
  preprod: { idUrl: 'https://id.pre', apiUrl: 'https://api.pre', portalUrl: 'https://portal.pre' },
  prod: { idUrl: 'https://id.prod', apiUrl: 'https://api.prod', portalUrl: 'https://portal.prod' },
};

function source(code: string | null = 'EG-674859545-TV'): PendingRow {
  return {
    fiscal_id: FISCAL,
    organization_id: ORG,
    environment: 'preprod',
    sale: {
      id: '55555555-5555-4555-8555-555555555555',
      number: 'MAIN-SL-26-000001',
      issued_at: '2026-10-12T09:15:02Z',
      prices_include_vat: true,
      total: '1140.00',
    },
    lines: [
      {
        line_no: 1,
        quantity: 1,
        unit_price: '1140.00',
        discount_amount: '0.00',
        tax_rate: '14.00',
        tax_amount: '140.00',
        line_total: '1140.00',
        sku: 'TV-55',
        name: 'TV',
        eta_item_code: code,
        eta_item_type: code === null ? null : 'EGS',
        eta_tax_type: 'T1',
        eta_subtype: 'V009',
      },
    ],
    payments: [{ method: 'cash', amount: '1140.00' }],
    customer: null,
    seller: {
      rin: '674859545',
      name: 'Shop',
      activity_code: '4753',
      branch_code: '0',
      governorate: 'Cairo',
      city: 'Nasr City',
      street: '16 St',
      building_number: '14',
    },
    device: {
      id: '22222222-2222-4222-8222-222222222222',
      serial: 'POS-1',
      status: 'active',
      is_active: true,
    },
  };
}

describe('buildCorrection', () => {
  const original = buildReceipt(source('EG-OLD'), PREVIOUS);
  const rejected = original.header.uuid;

  it('sets referenceOldUUID to the rejected UUID, keeps previousUUID and gives a new UUID', () => {
    const fixed = buildCorrection(source('EG-NEW'), PREVIOUS, rejected);
    expect(fixed.header.referenceOldUUID).toBe(rejected);
    expect(fixed.header.previousUUID).toBe(PREVIOUS);
    expect(fixed.header.uuid).toMatch(/^[0-9a-f]{64}$/);
    expect(fixed.header.uuid).not.toBe(rejected);
  });

  it('a first receipt of its POS keeps its empty previousUUID', () => {
    const first = buildReceipt(source('EG-OLD'), '');
    const fixed = buildCorrection(source('EG-NEW'), '', first.header.uuid);
    expect(fixed.header.previousUUID).toBe('');
  });

  it('a correction of a correction names the latest rejected UUID', () => {
    const first = buildCorrection(source('EG-NEW'), PREVIOUS, rejected);
    const second = buildCorrection(source('EG-NEWER'), PREVIOUS, first.header.uuid);
    expect(second.header.referenceOldUUID).toBe(first.header.uuid);
    expect(second.header.previousUUID).toBe(PREVIOUS);
  });

  it('refuses a reference that is not a UUID', () => {
    expect(() => buildCorrection(source(), PREVIOUS, 'nope')).toThrow(RangeError);
  });
});

describe('sameReceiptIgnoringChain', () => {
  const base = buildReceipt(source('EG-OLD'), PREVIOUS);
  const text = toJson(base);

  it('is the same receipt when only uuid, previousUUID and referenceOldUUID differ', () => {
    const corrected = toJson(buildCorrection(source('EG-OLD'), PREVIOUS, base.header.uuid));
    expect(corrected).not.toBe(text);
    expect(sameReceiptIgnoringChain(text, corrected)).toBe(true);
    expect(
      sameReceiptIgnoringChain(text, toJson(buildReceipt(source('EG-OLD'), 'b'.repeat(64)))),
    ).toBe(true);
  });

  it('is not the same when anything else differs', () => {
    expect(sameReceiptIgnoringChain(text, toJson(buildReceipt(source('EG-NEW'), PREVIOUS)))).toBe(
      false,
    );
    const other = source('EG-OLD');
    other.seller.city = 'Giza';
    expect(sameReceiptIgnoringChain(text, toJson(buildReceipt(other, PREVIOUS)))).toBe(false);
  });

  it('text that is not JSON is never the same', () => {
    expect(sameReceiptIgnoringChain('nope', 'nope')).toBe(false);
  });
});

describe('parseEtaError', () => {
  it('reads the masked line T02 stores: code, property path, message, details', () => {
    const parsed = parseEtaError(
      'ETA_INVALID: CV307 itemData[0].itemCode: bad item code; second thing; third',
    );
    expect(parsed).toEqual({
      message: 'bad item code',
      propertyPath: 'itemData[0].itemCode',
      details: ['second thing', 'third'],
      nothingChanged: false,
    });
  });

  it('reads an object with details', () => {
    const parsed = parseEtaError(
      `ETA_INVALID: ${JSON.stringify({
        message: 'Validation',
        propertyPath: 'seller.rin',
        details: [{ message: 'a' }, { message: 'b' }, 7],
      })}`,
    );
    expect(parsed).toMatchObject({
      message: 'Validation',
      propertyPath: 'seller.rin',
      details: ['a', 'b'],
    });
  });

  it('reads a plain string', () => {
    expect(parseEtaError('ETA_REJECTED: something went wrong')).toMatchObject({
      message: 'something went wrong',
      propertyPath: null,
      details: [],
    });
  });

  it('survives junk', () => {
    for (const junk of [null, undefined, 42, {}, '', '{not json', '{"details":5}', ':::', ';;;']) {
      const parsed = parseEtaError(junk);
      expect(typeof parsed.message).toBe('string');
      expect(Array.isArray(parsed.details)).toBe(true);
    }
  });

  it('knows the data was not fixed and shows the original error', () => {
    const note = correctionNote(
      'CORRECTION_NOTHING_CHANGED',
      'ETA_INVALID: CV307 itemData[0].itemCode: bad',
    );
    expect(note).toBe('CORRECTION_NOTHING_CHANGED: ETA_INVALID: CV307 itemData[0].itemCode: bad');
    expect(correctionNote('CORRECTION_NOTHING_CHANGED', note)).toBe(note);
    expect(originalEtaError(note)).toBe('ETA_INVALID: CV307 itemData[0].itemCode: bad');
    expect(parseEtaError(note)).toMatchObject({
      nothingChanged: true,
      propertyPath: 'itemData[0].itemCode',
    });
  });

  it('points a property at the screen that fixes it', () => {
    expect(fixForProperty('itemData[0].itemCode')).toBe('product');
    expect(fixForProperty('buyer.id')).toBe('customer');
    expect(fixForProperty('seller.branchAddress.street')).toBe('branch');
    expect(fixForProperty('seller.rin')).toBe('shop_profile');
    expect(fixForProperty('seller.activityCode')).toBe('eta_settings');
    expect(fixForProperty('header.dateTimeIssued')).toBe('support');
    expect(fixForProperty(null)).toBe('support');
  });
});

describe('error mapping', () => {
  it('maps the T03 codes to their statuses', () => {
    const cases: [string, number][] = [
      ['FISCAL_NOT_FOUND', 404],
      ['USE_CORRECTION: a rejected receipt is corrected, not resent', 409],
      ['NOT_REJECTED: the receipt is pending', 409],
      ['CORRECTION_QUEUED', 409],
      ['NOT_BLOCKED_NO_DEVICE', 409],
      ['NOT_SUBMITTED: the receipt is pending', 409],
      ['DEVICE_INVALID_FOR_RECEIPT', 400],
    ];
    for (const [message, status] of cases) {
      expect(mapDbError({ message })?.statusCode).toBe(status);
    }
    expect(errorCodeHttpStatus.CORRECTION_CONFLICT).toBe(409);
  });
});

describe('the eta.correct job', () => {
  const unused = () => Promise.reject(new Error('not used by eta.correct'));
  const OLD = buildReceipt(source('EG-OLD'), PREVIOUS);

  function run(loaded: CorrectionSource | null, fixture: PendingRow | null = source('EG-NEW')) {
    const calls = {
      stored: [] as { old: string; uuid: string; json: string; qr: string }[],
      notes: [] as string[],
      conflict: false,
    };
    const store: EtaStore = {
      loadPending: unused,
      credentials: unused,
      storePrepared: unused,
      block: unused,
      claimForSubmit: unused,
      mark: unused,
      loadSubmitted: unused,
      claimDeadlineAlerts: unused,
      enqueue: unused,
      saleStatus: unused,
      loadForCorrection: () =>
        Promise.resolve(loaded === null ? null : { ...loaded, row: loaded.row && fixture }),
      storeCorrection: (_id, old, uuid, json, qr) => {
        calls.stored.push({ old, uuid, json, qr });
        return Promise.resolve(calls.conflict ? 'conflict' : 'stored');
      },
      noteCorrection: (_id, _old, error) => {
        calls.notes.push(error);
        return Promise.resolve(true);
      },
    };
    const logs: string[] = [];
    const logger = createLogger({ level: 'trace', stream: { write: (l) => logs.push(l) } });
    const handlers = etaJobHandlers({
      store,
      client: { token: unused, submit: unused, submissionDetails: unused, lookup: unused },
      hosts: HOSTS,
      logger,
    });
    const job: Job = {
      id: 'job-1',
      organizationId: ORG,
      type: 'eta.correct',
      payload: { fiscal_id: FISCAL, expected_old_uuid: OLD.header.uuid },
      attempt: 1,
      maxAttempts: 5,
    };
    return { calls, logs, go: () => handlers['eta.correct'](job, logger) };
  }

  const rejectedRow = (over: Partial<CorrectionSource> = {}): CorrectionSource => ({
    status: 'rejected',
    eta_uuid: OLD.header.uuid,
    previous_uuid: PREVIOUS,
    last_error: 'ETA_INVALID: CV307 itemData[0].itemCode: bad',
    stored_receipt_json: toJson(OLD),
    row: source('EG-NEW'),
    ...over,
  });

  it('stores a correction with a new UUID, the same previousUUID and referenceOldUUID', async () => {
    const t = run(rejectedRow());
    await t.go();
    expect(t.calls.stored).toHaveLength(1);
    const stored = t.calls.stored[0];
    expect(stored?.old).toBe(OLD.header.uuid);
    expect(stored?.uuid).not.toBe(OLD.header.uuid);
    const json = JSON.parse(stored?.json ?? '{}') as { header: Record<string, string> };
    expect(json.header['referenceOldUUID']).toBe(OLD.header.uuid);
    expect(json.header['previousUUID']).toBe(PREVIOUS);
    expect(json.header['uuid']).toBe(stored?.uuid);
    expect(stored?.qr).toContain(stored?.uuid ?? 'x');
  });

  it('stores nothing when the data was not fixed, and says so', async () => {
    const t = run(rejectedRow(), source('EG-OLD'));
    await t.go();
    expect(t.calls.stored).toEqual([]);
    expect(t.calls.notes).toEqual([
      'CORRECTION_NOTHING_CHANGED: ETA_INVALID: CV307 itemData[0].itemCode: bad',
    ]);
  });

  it('says why when the data is still missing', async () => {
    const t = run(rejectedRow(), source(null));
    await t.go();
    expect(t.calls.stored).toEqual([]);
    expect(t.calls.notes[0]).toMatch(/^CORRECTION_BLOCKED_ITEM_CODE: ETA_INVALID/);
  });

  it('ends quietly when the receipt is not the rejected one the request saw', async () => {
    for (const loaded of [
      null,
      rejectedRow({ status: 'pending' }),
      rejectedRow({ eta_uuid: 'c'.repeat(64) }),
    ]) {
      const t = run(loaded);
      await t.go();
      expect(t.calls.stored).toEqual([]);
      expect(t.calls.notes).toEqual([]);
    }
  });

  it('CORRECTION_CONFLICT from the database ends the job without an error', async () => {
    const t = run(rejectedRow());
    t.calls.conflict = true;
    await expect(t.go()).resolves.toBeUndefined();
    expect(t.calls.stored).toHaveLength(1);
  });

  it('never logs the buyer national ID', async () => {
    const withId = source('EG-NEW');
    withId.customer = {
      name: 'Mona',
      national_id: '29901011234567',
      is_business: false,
      tax_registration_no: null,
    };
    const t = run(rejectedRow(), withId);
    await t.go();
    expect(t.logs.join('\n')).not.toContain('29901011234567');
  });
});
