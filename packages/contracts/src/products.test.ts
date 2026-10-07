import { describe, it, expect } from 'vitest';
import {
  Product,
  ProductCreateBody,
  ProductIdParams,
  ProductList,
  ProductListQuery,
  ProductLookupQuery,
  ProductUnitList,
  ProductUnitsQuery,
  ProductUpdateBody,
} from './products.js';
import { errorCodeHttpStatus } from './errors.js';

const product = {
  id: 'a0400000-0000-4000-8000-000000000001',
  name_ar: 'تلفزيون',
  name_en: 'TV',
  sku: 'TV-55',
  barcode: '2000000000015',
  category_id: null,
  unit_of_measure: 'piece',
  cash_price: '15000.00',
  installment_price: null,
  avg_cost: '0.0000',
  tax_class_id: 'a0400000-0000-4000-8000-000000000002',
  warranty_months: 12,
  is_serialized: false,
  min_stock: 0,
  image_file_id: null,
  eta_item_code: null,
  eta_item_type: null,
  archived_at: null,
  created_at: '2026-10-08T08:00:00.000Z',
  updated_at: '2026-10-08T08:00:00.000Z',
};

describe('C02 product contracts', () => {
  it('parses a product with money and cost as decimal strings', () => {
    expect(Product.parse(product)).toMatchObject({ cash_price: '15000.00', avg_cost: '0.0000' });
    expect(Product.safeParse({ ...product, cash_price: 15000 }).success).toBe(false);
    expect(Product.safeParse({ ...product, avg_cost: 0 }).success).toBe(false);
    expect(
      ProductList.parse({ items: [product], page: 1, pageSize: 50, total: 1 }).items,
    ).toHaveLength(1);
  });

  it('trims and upper-cases the SKU and enforces its pattern', () => {
    const body = ProductCreateBody.parse({
      name_ar: ' كابل ',
      sku: ' cb-1/a.b_c ',
      cash_price: '1',
    });
    expect(body).toMatchObject({ name_ar: 'كابل', sku: 'CB-1/A.B_C' });
    expect(
      ProductCreateBody.safeParse({ name_ar: 'x', sku: 'CB 1', cash_price: '1' }).success,
    ).toBe(false);
    expect(ProductCreateBody.safeParse({ name_ar: 'x', sku: '', cash_price: '1' }).success).toBe(
      false,
    );
    expect(
      ProductCreateBody.safeParse({ name_ar: 'x', sku: 'X'.repeat(41), cash_price: '1' }).success,
    ).toBe(false);
  });

  it('requires name_ar, sku and cash_price on create', () => {
    expect(ProductCreateBody.safeParse({ sku: 'A', cash_price: '1' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ name_ar: 'x', cash_price: '1' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ name_ar: 'x', sku: 'A' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ name_ar: ' ', sku: 'A', cash_price: '1' }).success).toBe(
      false,
    );
  });

  it('strict bodies reject avg_cost, organization_id, is_active and archived_at', () => {
    const base = { name_ar: 'x', sku: 'A', cash_price: '1' };
    for (const extra of [
      { avg_cost: '1' },
      { organization_id: 'a0400000-0000-4000-8000-000000000009' },
      { is_active: true },
      { archived_at: null },
    ]) {
      expect(ProductCreateBody.safeParse({ ...base, ...extra }).success).toBe(false);
      expect(ProductUpdateBody.safeParse(extra).success).toBe(false);
    }
  });

  it('accepts money strings only, never negative or with three decimals', () => {
    const base = { name_ar: 'x', sku: 'A' };
    expect(ProductCreateBody.safeParse({ ...base, cash_price: '10.50' }).success).toBe(true);
    expect(ProductCreateBody.safeParse({ ...base, cash_price: 10.5 }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, cash_price: '-1' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, cash_price: '1.005' }).success).toBe(false);
    expect(
      ProductCreateBody.safeParse({ ...base, cash_price: '1', installment_price: null }).success,
    ).toBe(true);
    expect(
      ProductCreateBody.safeParse({ ...base, cash_price: '1', installment_price: '-2' }).success,
    ).toBe(false);
  });

  it('empty or null barcode means generate; otherwise 4-32 letters, digits or dashes', () => {
    const base = { name_ar: 'x', sku: 'A', cash_price: '1' };
    expect(ProductCreateBody.parse({ ...base, barcode: '' }).barcode).toBeNull();
    expect(ProductCreateBody.parse({ ...base, barcode: '  ' }).barcode).toBeNull();
    expect(ProductCreateBody.parse({ ...base, barcode: null }).barcode).toBeNull();
    expect(ProductCreateBody.parse({ ...base, barcode: ' 6223-001 ' }).barcode).toBe('6223-001');
    expect(ProductCreateBody.safeParse({ ...base, barcode: '123' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, barcode: '12 34' }).success).toBe(false);
    expect(ProductUpdateBody.parse({ barcode: null })).toEqual({ barcode: null });
  });

  it('ETA code and type go together', () => {
    const base = { name_ar: 'x', sku: 'A', cash_price: '1' };
    expect(ProductCreateBody.safeParse({ ...base, eta_item_code: 'EG-1' }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, eta_item_type: 'EGS' }).success).toBe(false);
    expect(
      ProductCreateBody.safeParse({ ...base, eta_item_code: 'EG-1', eta_item_type: 'GS1' }).success,
    ).toBe(true);
    expect(
      ProductCreateBody.safeParse({ ...base, eta_item_code: 'EG-1', eta_item_type: 'ABC' }).success,
    ).toBe(false);
    // On update, a single key is checked by the server against the stored value.
    expect(ProductUpdateBody.safeParse({ eta_item_code: 'EG-2' }).success).toBe(true);
    expect(
      ProductUpdateBody.safeParse({ eta_item_code: 'EG-2', eta_item_type: null }).success,
    ).toBe(false);
    expect(ProductUpdateBody.safeParse({ eta_item_code: null, eta_item_type: null }).success).toBe(
      true,
    );
  });

  it('checks the integer fields', () => {
    const base = { name_ar: 'x', sku: 'A', cash_price: '1' };
    expect(ProductCreateBody.safeParse({ ...base, warranty_months: 121 }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, warranty_months: 1.5 }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, min_stock: -1 }).success).toBe(false);
    expect(ProductCreateBody.safeParse({ ...base, min_stock: 1_000_001 }).success).toBe(false);
  });

  it('update needs at least one key', () => {
    expect(ProductUpdateBody.safeParse({}).success).toBe(false);
    expect(ProductUpdateBody.parse({ sku: 'ab' })).toEqual({ sku: 'AB' });
  });

  it('list query defaults: active, with subcategories, first page', () => {
    expect(ProductListQuery.parse({})).toEqual({
      page: 1,
      pageSize: 50,
      include_subcategories: true,
      status: 'active',
      search: undefined,
    });
    expect(
      ProductListQuery.parse({ include_subcategories: 'false', status: 'all', search: '  tv ' }),
    ).toMatchObject({ include_subcategories: false, status: 'all', search: 'tv' });
    expect(ProductListQuery.parse({ search: '   ' }).search).toBeUndefined();
    expect(ProductListQuery.safeParse({ status: 'deleted' }).success).toBe(false);
    expect(ProductListQuery.safeParse({ include_subcategories: 'yes' }).success).toBe(false);
    expect(ProductListQuery.safeParse({ search: 'x'.repeat(101) }).success).toBe(false);
    expect(ProductListQuery.safeParse({ organization_id: product.id }).success).toBe(false);
  });

  it('lookup code is trimmed, 1-64', () => {
    expect(ProductLookupQuery.parse({ code: ' 2000000000015 ' })).toEqual({
      code: '2000000000015',
    });
    expect(ProductLookupQuery.safeParse({ code: ' ' }).success).toBe(false);
    expect(ProductLookupQuery.safeParse({ code: 'x'.repeat(65) }).success).toBe(false);
    expect(ProductIdParams.safeParse({ id: 'nope' }).success).toBe(false);
  });

  it('has the five product error codes', () => {
    expect(errorCodeHttpStatus).toMatchObject({
      PRODUCT_NOT_FOUND: 404,
      PRODUCT_SKU_TAKEN: 409,
      PRODUCT_BARCODE_TAKEN: 409,
      PRODUCT_SERIAL_LOCKED: 409,
      PRODUCT_CATEGORY_ARCHIVED: 409,
    });
  });

  it('C03: units of a product, in stock by default', () => {
    expect(ProductUnitsQuery.parse({})).toEqual({ status: 'in_stock' });
    expect(ProductUnitsQuery.parse({ status: 'all' })).toEqual({ status: 'all' });
    expect(ProductUnitsQuery.safeParse({ status: 'lost' }).success).toBe(false);
    expect(ProductUnitsQuery.safeParse({ branch_id: product.id }).success).toBe(false);
    const unit = { id: product.id, serial: 'IMEI-1', branch_id: product.id, status: 'in_stock' };
    expect(ProductUnitList.parse([unit])).toEqual([unit]);
    expect(ProductUnitList.safeParse([{ ...unit, status: 'gone' }]).success).toBe(false);
  });
});
