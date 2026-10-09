import { describe, it, expect } from 'vitest';
import {
  Supplier,
  SupplierCreateBody,
  SupplierIdParams,
  SupplierList,
  SupplierListQuery,
  SupplierStatement,
  SupplierStatementQuery,
  SupplierUpdateBody,
  normalizeSupplierPhone,
} from './suppliers.js';
import { errorCodeHttpStatus } from './errors.js';

const supplier = {
  id: 'a0530000-0000-4000-8000-000000000001',
  name: 'Nile Traders',
  phone: '01012345678',
  tax_registration_no: '123-456-789',
  address: 'Cairo',
  payment_terms_days: 30,
  notes: null,
  archived_at: null,
  created_at: '2026-10-11T08:00:00.000Z',
  updated_at: '2026-10-11T08:00:00.000Z',
  balance: '1050.25',
};

const row = {
  date: '2026-09-01',
  kind: 'invoice',
  document_id: 'a0530000-0000-4000-8000-000000000002',
  number: 'PI-2026-000001',
  reference: 'S-100',
  branch_id: 'a0530000-0000-4000-8000-000000000003',
  refund_mode: null,
  debit: '1000.00',
  credit: '0.00',
  balance: '1000.00',
};

describe('U01 supplier contracts', () => {
  it('parses a supplier with the balance as a decimal string', () => {
    expect(Supplier.parse(supplier)).toMatchObject({ balance: '1050.25' });
    expect(Supplier.parse({ ...supplier, balance: '-20.00' }).balance).toBe('-20.00');
    expect(Supplier.safeParse({ ...supplier, balance: 1050.25 }).success).toBe(false);
    expect(SupplierList.parse({ items: [supplier], page: 1, pageSize: 50, total: 1 }).total).toBe(
      1,
    );
  });

  it('create: trims, normalises the phone, defaults the terms to 0', () => {
    const body = SupplierCreateBody.parse({
      name: '  Nile Traders ',
      phone: ' 010-1234 5678 ',
      tax_registration_no: ' 123-456-789 ',
      address: ' Cairo ',
      notes: '',
    });
    expect(body).toEqual({
      name: 'Nile Traders',
      phone: '01012345678',
      tax_registration_no: '123-456-789',
      address: 'Cairo',
      payment_terms_days: 0,
      notes: null,
    });
    expect(SupplierCreateBody.parse({ name: 'X', phone: '+20 100 000 0001' }).phone).toBe(
      '+201000000001',
    );
    expect(SupplierCreateBody.parse({ name: 'X', phone: '' }).phone).toBeNull();
    expect(SupplierCreateBody.parse({ name: 'X', phone: null }).phone).toBeNull();
    expect(normalizeSupplierPhone('010 - 12 34')).toBe('0101234');
  });

  it('create: refuses a missing or long name, bad phones, tax numbers and terms', () => {
    const bad = [
      {},
      { name: '   ' },
      { name: 'n'.repeat(151) },
      { name: 'X', phone: '01ab234567' },
      { name: 'X', phone: '12345' },
      { name: 'X', phone: '1234567890123456' },
      { name: 'X', phone: '++201000' },
      { name: 'X', tax_registration_no: '12-34' },
      { name: 'X', tax_registration_no: '12345678A' },
      { name: 'X', address: 'a'.repeat(301) },
      { name: 'X', notes: 'n'.repeat(1001) },
      { name: 'X', payment_terms_days: 366 },
      { name: 'X', payment_terms_days: -1 },
      { name: 'X', payment_terms_days: 1.5 },
      { name: 'X', payment_terms_days: '30' },
    ];
    for (const b of bad)
      expect(SupplierCreateBody.safeParse(b).success, JSON.stringify(b)).toBe(false);
    expect(SupplierCreateBody.safeParse({ name: 'X', payment_terms_days: 365 }).success).toBe(true);
  });

  it('create and update are strict: no organization_id, archived_at or unknown keys', () => {
    expect(
      SupplierCreateBody.safeParse({
        name: 'X',
        organization_id: 'a0530000-0000-4000-8000-000000000009',
      }).success,
    ).toBe(false);
    expect(SupplierCreateBody.safeParse({ name: 'X', category: 'general' }).success).toBe(false);
    expect(SupplierUpdateBody.safeParse({ archived_at: null }).success).toBe(false);
    expect(SupplierUpdateBody.safeParse({ balance: '0.00' }).success).toBe(false);
  });

  it('update: any field, at least one; null clears an optional field', () => {
    expect(SupplierUpdateBody.safeParse({}).success).toBe(false);
    expect(SupplierUpdateBody.parse({ phone: '010-1234-5678' })).toEqual({ phone: '01012345678' });
    expect(SupplierUpdateBody.parse({ phone: null, notes: ' ' })).toEqual({
      phone: null,
      notes: null,
    });
    expect(SupplierUpdateBody.parse({ payment_terms_days: 45 })).toEqual({
      payment_terms_days: 45,
    });
    expect(SupplierUpdateBody.safeParse({ name: null }).success).toBe(false);
  });

  it('list query: defaults, trimmed search, strict', () => {
    expect(SupplierListQuery.parse({})).toEqual({ page: 1, pageSize: 50, status: 'active' });
    expect(SupplierListQuery.parse({ search: '  nile ', status: 'all', page: '2' })).toEqual({
      search: 'nile',
      status: 'all',
      page: 2,
      pageSize: 50,
    });
    expect(SupplierListQuery.parse({ search: '   ' }).search).toBeUndefined();
    expect(SupplierListQuery.safeParse({ search: 's'.repeat(101) }).success).toBe(false);
    expect(SupplierListQuery.safeParse({ status: 'deleted' }).success).toBe(false);
    expect(
      SupplierListQuery.safeParse({ organization_id: 'a0530000-0000-4000-8000-000000000009' })
        .success,
    ).toBe(false);
  });

  it('params and statement query', () => {
    expect(SupplierIdParams.safeParse({ id: 'not-a-uuid' }).success).toBe(false);
    expect(SupplierStatementQuery.parse({})).toEqual({});
    expect(SupplierStatementQuery.parse({ from: '2026-09-01', to: '2026-09-01' })).toEqual({
      from: '2026-09-01',
      to: '2026-09-01',
    });
    expect(SupplierStatementQuery.safeParse({ from: '2026-09-02', to: '2026-09-01' }).success).toBe(
      false,
    );
    expect(SupplierStatementQuery.safeParse({ from: '2026-02-30' }).success).toBe(false);
    expect(SupplierStatementQuery.safeParse({ branch_id: row.branch_id }).success).toBe(false);
  });

  it('statement shape: rows with debit, credit and the running balance', () => {
    const statement = {
      supplier,
      from: null,
      to: null,
      opening_balance: '0.00',
      closing_balance: '1050.25',
      totals: { invoiced: '1500.50', paid: '400.00', returned: '50.25' },
      rows: [
        row,
        { ...row, kind: 'payment_reversal', reference: null, debit: '100.00', balance: '1100.00' },
        { ...row, kind: 'return', refund_mode: 'cash', debit: '0.00', balance: '1100.00' },
      ],
    };
    expect(SupplierStatement.parse(statement).rows).toHaveLength(3);
    expect(SupplierStatement.safeParse({ ...statement, from: '2026-09-01' }).success).toBe(true);
    expect(
      SupplierStatement.safeParse({ ...statement, rows: [{ ...row, kind: 'sale' }] }).success,
    ).toBe(false);
    expect(
      SupplierStatement.safeParse({ ...statement, rows: [{ ...row, refund_mode: 'store' }] })
        .success,
    ).toBe(false);
    expect(SupplierStatement.safeParse({ ...statement, closing_balance: 1050.25 }).success).toBe(
      false,
    );
  });

  it('the new error codes and their HTTP status', () => {
    expect(errorCodeHttpStatus.SUPPLIER_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.SUPPLIER_NAME_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.SUPPLIER_PHONE_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.SUPPLIER_HAS_BALANCE).toBe(409);
    expect(errorCodeHttpStatus.SUPPLIER_HAS_OPEN_DOCUMENTS).toBe(409);
  });
});
