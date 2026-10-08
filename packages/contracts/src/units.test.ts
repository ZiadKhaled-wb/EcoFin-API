import { describe, it, expect } from 'vitest';
import {
  SerialTakenDetail,
  UnitDetail,
  UnitFindQuery,
  UnitRegisterBody,
  UnitSearchQuery,
} from './units.js';

const ID = 'a0d00000-0000-4000-8000-000000000001';
const body = { product_id: ID, branch_id: ID, cost: '7000.50', serials: [' imei-1 ', 'IMEI-2'] };

describe('I04 unit contracts', () => {
  it('serials are trimmed and upper-cased; repeats, bad serials and bad cost are refused', () => {
    expect(UnitRegisterBody.parse(body)).toEqual({
      ...body,
      serials: ['IMEI-1', 'IMEI-2'],
      note: undefined,
    });
    expect(UnitRegisterBody.safeParse({ ...body, serials: ['imei-1', 'IMEI-1'] }).success).toBe(
      false,
    );
    expect(UnitRegisterBody.safeParse({ ...body, serials: ['bad serial!'] }).success).toBe(false);
    expect(UnitRegisterBody.safeParse({ ...body, serials: [] }).success).toBe(false);
    expect(UnitRegisterBody.safeParse({ ...body, cost: '-1' }).success).toBe(false);
    expect(UnitRegisterBody.safeParse({ ...body, cost: 7000 }).success).toBe(false);
    expect(UnitRegisterBody.safeParse({ ...body, organization_id: ID }).success).toBe(false);
  });

  it('a unit with its history; queries', () => {
    const unit = {
      id: ID,
      serial: 'IMEI-1',
      product_id: ID,
      name_ar: 'موبايل',
      name_en: null,
      sku: 'PH',
      branch_id: ID,
      branch_name: 'Main',
      status: 'sold',
      cost: '7000.50',
      created_at: '2026-10-10T08:00:00.000Z',
      purchase_invoice_id: null,
      purchase_invoice_number: null,
      supplier_name: null,
      history: [
        {
          id: ID,
          created_at: '2026-10-10T08:00:00.000Z',
          business_date: '2026-10-10',
          type: 'sale_out',
          quantity: -1,
          branch_id: ID,
          branch_name: 'Main',
          source_type: 'sale',
          source_id: ID,
          source_number: 'MAIN-SL-26-000001',
          party_name: 'Buyer',
          reason: null,
          created_by_name: 'Cashier',
        },
      ],
    };
    expect(UnitDetail.parse(unit)).toEqual(unit);
    expect(UnitDetail.safeParse({ ...unit, status: 'lost' }).success).toBe(false);
    expect(UnitSearchQuery.parse({ search: ' imei ', status: 'sold' })).toMatchObject({
      search: 'imei',
      page: 1,
    });
    expect(UnitFindQuery.safeParse({ serial: ' ' }).success).toBe(false);
    expect(SerialTakenDetail.parse({ serials: ['IMEI-1'] })).toEqual({ serials: ['IMEI-1'] });
  });
});
