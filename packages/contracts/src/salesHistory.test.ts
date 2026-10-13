import { describe, expect, it } from 'vitest';
import { SaleReceiptPrint, SalesHistoryQuery, SaleVoidBody, SaleStatus } from './salesHistory.js';

describe('S07 sales history contracts', () => {
  it('validates filters and pagination without client organization context', () => {
    expect(SalesHistoryQuery.parse({ q: ' SL ', page: '2', page_size: '20' })).toMatchObject({
      q: 'SL',
      page: 2,
      page_size: 20,
    });
    for (const query of [
      { organization_id: 'other' },
      { page: 0 },
      { page_size: 101 },
      { status: 'unknown' },
      { from: 'bad' },
      { from: '2026-10-13', to: '2026-10-12' },
    ]) {
      expect(SalesHistoryQuery.safeParse(query).success).toBe(false);
    }
  });
  it('requires a trimmed reason of three to two hundred characters', () => {
    expect(SaleVoidBody.parse({ reason: '  Duplicate  ' })).toEqual({ reason: 'Duplicate' });
    for (const body of [
      {},
      { reason: '  ' },
      { reason: 'ab' },
      { reason: 'x'.repeat(201) },
      { reason: 'Valid', organization_id: 'other' },
    ]) {
      expect(SaleVoidBody.safeParse(body).success).toBe(false);
    }
  });
  it.each(['completed', 'voided', 'returned', 'partially_returned'])(
    'accepts computed status %s',
    (status) => {
      expect(SaleStatus.parse(status)).toBe(status);
    },
  );
  it('S04: a receipt print has a number from 1 and says whether it is a copy', () => {
    expect(SaleReceiptPrint.parse({ print_no: 1, copy: false })).toEqual({
      print_no: 1,
      copy: false,
    });
    expect(SaleReceiptPrint.safeParse({ print_no: 0, copy: false }).success).toBe(false);
    expect(SaleReceiptPrint.safeParse({ print_no: 2 }).success).toBe(false);
  });
});
