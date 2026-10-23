import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { dec } from '@ziadkhaled-wb/contracts';
import { receiptUuid, UUID_PATTERN, withUuid } from './uuid';

const receipt = (previousUUID = '', uuid = '') => ({
  header: {
    dateTimeIssued: '2026-10-12T09:15:02Z',
    receiptNumber: 'MAIN-SL-26-000001',
    uuid,
    previousUUID,
  },
  totalAmount: dec('1026.00'),
});

describe('ETA receipt UUID', () => {
  it('is the SHA-256 of the serialized receipt with an empty uuid, as 64 lower-case hex', () => {
    const serialized =
      '"HEADER""DATETIMEISSUED""2026-10-12T09:15:02Z""RECEIPTNUMBER""MAIN-SL-26-000001"' +
      '"UUID""""PREVIOUSUUID""""TOTALAMOUNT""1026.00"';
    const expected = createHash('sha256').update(serialized, 'utf8').digest('hex');
    const uuid = receiptUuid(receipt());
    expect(uuid).toBe(expected);
    expect(uuid).toMatch(/^[0-9a-f]{64}$/);
    expect(UUID_PATTERN.test(uuid)).toBe(true);
  });

  it('ignores whatever the uuid field holds', () => {
    const blank = receiptUuid(receipt('', ''));
    expect(receiptUuid(receipt('', 'f'.repeat(64)))).toBe(blank);
    expect(receiptUuid(receipt('', blank))).toBe(blank);
  });

  it('changes when previousUUID changes', () => {
    const first = receiptUuid(receipt(''));
    const second = receiptUuid(receipt(first));
    const other = receiptUuid(receipt('a'.repeat(64)));
    expect(new Set([first, second, other]).size).toBe(3);
  });

  it('a POS\'s first receipt is hashed with previousUUID ""', () => {
    const first = receipt('');
    expect(first.header.previousUUID).toBe('');
    expect(receiptUuid(first)).toBe(receiptUuid(receipt()));
    expect(receiptUuid(first)).not.toBe(receiptUuid(receipt('0')));
  });

  it('changes with any other content, non-ASCII included (UTF-8)', () => {
    const base = { header: { uuid: '', previousUUID: '' }, seller: { name: 'محل النور' } };
    const other = { header: { uuid: '', previousUUID: '' }, seller: { name: 'محل النور ' } };
    expect(receiptUuid(base)).not.toBe(receiptUuid(other));
    expect(receiptUuid(base)).toBe(
      createHash('sha256')
        .update('"HEADER""UUID""""PREVIOUSUUID""""SELLER""NAME""محل النور"', 'utf8')
        .digest('hex'),
    );
  });

  it('withUuid fills the uuid in and keeps the property order', () => {
    const filled = withUuid(receipt('', 'stale'));
    expect(filled.header.uuid).toBe(receiptUuid(receipt()));
    expect(Object.keys(filled.header)).toEqual([
      'dateTimeIssued',
      'receiptNumber',
      'uuid',
      'previousUUID',
    ]);
    expect(Object.keys(filled)).toEqual(['header', 'totalAmount']);
    // Filling it in doesn't change it: the UUID of a finished receipt is its own uuid.
    expect(receiptUuid(filled)).toBe(filled.header.uuid);
  });
});
