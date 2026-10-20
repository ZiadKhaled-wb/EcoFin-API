import { describe, it, expect } from 'vitest';
import {
  CreateImportBody,
  IMPORT_COLUMNS,
  IMPORT_KINDS,
  IMPORT_ROW_ERROR_CODES,
  ImportListQuery,
  ImportReport,
  missingImportColumns,
  normalizeImportHeader,
  suggestImportMapping,
} from './imports.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0d00000-0000-4000-8000-000000000001';
const KEY = 'import-key-0001';

describe('M01 import contracts', () => {
  it('every kind has unique field keys and the required ones are marked', () => {
    for (const kind of IMPORT_KINDS) {
      const keys = IMPORT_COLUMNS[kind].map((c) => c.key);
      expect(new Set(keys).size).toBe(keys.length);
      expect(IMPORT_COLUMNS[kind].some((c) => c.required || c.requiredOneOf)).toBe(true);
      for (const c of IMPORT_COLUMNS[kind]) {
        expect(c.label_ar.length).toBeGreaterThan(0);
        expect(c.label_en.length).toBeGreaterThan(0);
        expect(c.help_ar.length).toBeGreaterThan(0);
        expect(c.help_en.length).toBeGreaterThan(0);
      }
    }
  });

  it('no two fields of a kind answer to the same header name', () => {
    for (const kind of IMPORT_KINDS) {
      const seen = new Map<string, string>();
      for (const c of IMPORT_COLUMNS[kind]) {
        const names = [c.key, c.label_en, c.label_ar, ...c.aliases].map(normalizeImportHeader);
        for (const n of new Set(names)) {
          const other = seen.get(n);
          expect(
            other === undefined || other === c.key,
            `${kind}: "${n}" -> ${other}/${c.key}`,
          ).toBe(true);
          seen.set(n, c.key);
        }
      }
    }
  });

  it('headers are compared without case, spaces, punctuation, harakat or Arabic forms', () => {
    expect(normalizeImportHeader(' Item-Code ')).toBe('itemcode');
    expect(normalizeImportHeader('ITEM_CODE')).toBe('itemcode');
    expect(normalizeImportHeader('اسم الصنف')).toBe(normalizeImportHeader('إسم الصنف'));
    expect(normalizeImportHeader('كود١٢')).toBe('كود12');
  });

  it('matches a shop’s own English and Arabic headers', () => {
    const products = suggestImportMapping('products', [
      'Item Code',
      'Product Name',
      'Price',
      'Brand',
      'الباركود',
      'التصنيف',
    ]);
    expect(products.mapping).toEqual({
      sku: 'Item Code',
      name_ar: 'Product Name',
      cash_price: 'Price',
      barcode: 'الباركود',
      category: 'التصنيف',
    });
    expect(products.unmapped_headers).toEqual(['Brand']);
    expect(products.missing_required).toEqual([]);

    const customers = suggestImportMapping('customers', ['اسم العميل', 'الموبايل', 'الرقم القومي']);
    expect(customers.mapping).toEqual({
      full_name: 'اسم العميل',
      phones: 'الموبايل',
      national_id: 'الرقم القومي',
    });
  });

  it('the template headers (the key itself) always match their own field', () => {
    for (const kind of IMPORT_KINDS) {
      const headers = IMPORT_COLUMNS[kind].map((c) => c.key);
      const s = suggestImportMapping(kind, headers);
      expect(Object.keys(s.mapping).sort()).toEqual([...headers].sort());
      expect(s.unmapped_headers).toEqual([]);
    }
  });

  it('reports what is missing, groups as "a|b"', () => {
    expect(missingImportColumns('products', ['sku', 'name_ar'])).toEqual(['cash_price']);
    expect(missingImportColumns('products', ['cash_price'])).toEqual([
      'sku|barcode',
      'name_ar|name_en',
    ]);
    expect(missingImportColumns('opening_stock', ['barcode', 'quantity', 'unit_cost'])).toEqual([]);
    expect(missingImportColumns('opening_stock', ['sku'])).toEqual([
      'unit_cost',
      'quantity|serial',
    ]);
    expect(missingImportColumns('suppliers', [])).toEqual(['name']);
  });

  it('create body: opening stock needs a branch, other kinds refuse one, mapping keys must exist', () => {
    const base = { kind: 'products', file_id: ID, idempotency_key: KEY } as const;
    expect(CreateImportBody.safeParse(base).success).toBe(true);
    expect(CreateImportBody.safeParse({ ...base, kind: 'opening_stock' }).success).toBe(false);
    expect(
      CreateImportBody.safeParse({ ...base, kind: 'opening_stock', branch_id: ID }).success,
    ).toBe(true);
    expect(CreateImportBody.safeParse({ ...base, branch_id: ID }).success).toBe(false);
    expect(CreateImportBody.safeParse({ ...base, mapping: { sku: 'Code' } }).success).toBe(true);
    expect(CreateImportBody.safeParse({ ...base, mapping: { nope: 'Code' } }).success).toBe(false);
    expect(CreateImportBody.safeParse({ ...base, organization_id: ID }).success).toBe(false);
    expect(CreateImportBody.safeParse({ ...base, idempotency_key: 'short' }).success).toBe(false);
  });

  it('list query defaults and limits', () => {
    expect(ImportListQuery.parse({}).limit).toBe(25);
    expect(ImportListQuery.safeParse({ limit: '101' }).success).toBe(false);
    expect(ImportListQuery.safeParse({ kind: 'opening_cash' }).success).toBe(false);
  });

  it('a report shape', () => {
    const report = {
      columns: { mapping: { sku: 'Code' }, unmapped_headers: [] },
      sheet: null,
      branch_id: null,
      warnings: [],
      errors: [{ row: 3, column: 'name_ar', code: 'IMPORT_REQUIRED', message: 'name_ar' }],
      errors_total: 1,
      errors_truncated: false,
      actions: { create: 1, update: 0, unchanged: 0 },
      preview: [{ row: 2, action: 'create', values: { sku: 'A' } }],
      will_create_categories: [],
      applied: null,
      failure: null,
    };
    expect(ImportReport.parse(report)).toEqual(report);
    expect(
      ImportReport.safeParse({ ...report, errors: [{ ...report.errors[0], code: 'X' }] }).success,
    ).toBe(false);
  });

  it('the field keys of each kind are the ones the SQL import reads (app.import_kind_columns)', () => {
    // Keep this list equal to the one in supabase/tests/m01_import_test.sql.
    const expected = {
      suppliers: ['name', 'phone', 'tax_registration_no', 'address', 'payment_terms_days', 'notes'],
      products: [
        'sku',
        'name_ar',
        'name_en',
        'cash_price',
        'barcode',
        'category',
        'unit_of_measure',
        'installment_price',
        'tax_class',
        'warranty_months',
        'is_serialized',
        'min_stock',
        'eta_item_code',
        'eta_item_type',
      ],
      customers: [
        'full_name',
        'phones',
        'national_id',
        'birth_date',
        'gender',
        'address',
        'city',
        'job',
        'employer',
        'monthly_income',
        'is_business',
        'tax_registration_no',
        'notes',
      ],
      opening_stock: ['sku', 'barcode', 'quantity', 'serial', 'unit_cost'],
    };
    for (const kind of IMPORT_KINDS) {
      expect(IMPORT_COLUMNS[kind].map((c) => c.key)).toEqual(expected[kind]);
    }
  });

  it('the row error codes are the ones app.import_row_codes() reports', () => {
    expect([...IMPORT_ROW_ERROR_CODES]).toEqual([
      'IMPORT_REQUIRED',
      'IMPORT_INVALID_VALUE',
      'IMPORT_DUPLICATE_ROW',
      'IMPORT_AMBIGUOUS_MATCH',
      'IMPORT_APPLY_FAILED',
      'PRODUCT_ARCHIVED',
      'PRODUCT_NOT_FOUND',
      'PRODUCT_SKU_TAKEN',
      'PRODUCT_BARCODE_TAKEN',
      'PRODUCT_SERIAL_LOCKED',
      'PRODUCT_CATEGORY_ARCHIVED',
      'CATEGORY_DEPTH',
      'CATEGORY_NAME_TAKEN',
      'CUSTOMER_NATIONAL_ID_TAKEN',
      'CUSTOMER_NATIONAL_ID_LOCKED',
      'NATIONAL_ID_INVALID',
      'SUPPLIER_PHONE_TAKEN',
      'SUPPLIER_NAME_TAKEN',
      'SERIAL_INVALID',
      'SERIAL_TAKEN',
      'UNIT_NOT_ALLOWED',
      'UNIT_REQUIRED',
      'OPENING_STOCK_LOCKED',
      'TAX_CLASS_NOT_FOUND',
      'MODULE_NOT_IN_PLAN',
      'OUT_OF_STOCK',
    ]);
  });

  it('the new HTTP error codes', () => {
    expect(errorCodeHttpStatus.IMPORT_TOO_MANY_ROWS).toBe(413);
    expect(errorCodeHttpStatus.IMPORT_NOT_VALIDATED).toBe(409);
    expect(errorCodeHttpStatus.IMPORT_JOB_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.IMPORT_FILE_UNREADABLE).toBe(422);
  });
});
