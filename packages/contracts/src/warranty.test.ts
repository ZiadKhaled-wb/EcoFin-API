import { describe, it, expect } from 'vitest';
import {
  WarrantyLookupQuery,
  OpenWarrantyClaimBody,
  MoveWarrantyClaimBody,
  WarrantyClaimsQuery,
} from './warranty.js';
const id = 'a7120000-0000-4000-8000-000000000001';
describe('S12 warranty contracts', () => {
  it('requires exactly one trimmed lookup key and rejects tenant injection', () => {
    expect(WarrantyLookupQuery.parse({ serial: ' A ' }).serial).toBe('A');
    for (const q of [
      {},
      { serial: 'A', phone: '010' },
      { serial: ' ' },
      { serial: 'A', organization_id: id },
    ])
      expect(WarrantyLookupQuery.safeParse(q).success).toBe(false);
  });
  it('bounds issue and received condition', () => {
    expect(
      OpenWarrantyClaimBody.safeParse({ sale_line_id: id, issue: 'Broken', condition: 'Scratched' })
        .success,
    ).toBe(true);
    for (const body of [
      { sale_line_id: id, issue: 'ab', condition: 'Fine' },
      { sale_line_id: id, issue: 'x'.repeat(501), condition: 'Fine' },
      { sale_line_id: id, issue: 'Broken', condition: 'x'.repeat(301) },
    ])
      expect(OpenWarrantyClaimBody.safeParse(body).success).toBe(false);
  });
  it('requires rejection and replacement notes and excludes refunds', () => {
    expect(MoveWarrantyClaimBody.safeParse({ to: 'rejected' }).success).toBe(false);
    expect(MoveWarrantyClaimBody.safeParse({ to: 'replaced', note: 'Swap' }).success).toBe(true);
    expect(MoveWarrantyClaimBody.safeParse({ to: 'refunded' }).success).toBe(false);
  });
  it('parses boolean filters literally and bounds paging', () => {
    expect(WarrantyClaimsQuery.parse({ out_of_warranty: 'false' }).out_of_warranty).toBe(false);
    expect(WarrantyClaimsQuery.parse({ out_of_warranty: 'true' }).out_of_warranty).toBe(true);
    expect(WarrantyClaimsQuery.safeParse({ page_size: 101 }).success).toBe(false);
  });
});
