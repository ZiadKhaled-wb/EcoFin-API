import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import {
  approvePurchaseInvoice,
  createPurchaseInvoice,
  getPurchaseInvoice,
  listPurchaseInvoices,
  rejectPurchaseInvoice,
  updatePurchaseInvoice,
} from './purchases.service';

const ID = 'a0540000-0000-4000-8000-000000000020';
const SUPPLIER = 'a0540000-0000-4000-8000-000000000001';
const BRANCH = 'a0540000-0000-4000-8000-000000000002';
const TV = 'a0540000-0000-4000-8000-000000000003';
const PHONE = 'a0540000-0000-4000-8000-000000000004';
const CLASS = 'a0540000-0000-4000-8000-000000000005';
const ts = '2026-10-11T08:00:00.000Z';
const KEY = 'pi-key-0001';

const header = {
  id: ID,
  number: 'BR1-PI-26-000001',
  supplier_id: SUPPLIER,
  supplier_name: 'Nile Traders',
  branch_id: BRANCH,
  supplier_invoice_no: null,
  invoice_date: '2026-10-10',
  status: 'draft',
  subtotal: '1300.00',
  tax_total: '182.00',
  total: '1482.00',
  outstanding: null,
  approved_by_name: null,
  approved_at: null,
  rejected_reason: null,
  created_by_name: 'Owner',
  created_at: ts,
  updated_at: ts,
};
const invoice = (extra: Record<string, unknown> = {}) => ({
  ...header,
  lines: [
    {
      id: 'a0540000-0000-4000-8000-000000000010',
      product_id: TV,
      name_ar: 'تلفزيون',
      name_en: null,
      sku: 'TV-55',
      is_serialized: false,
      quantity: 10,
      unit_cost: '130.00',
      tax_class_id: CLASS,
      tax_rate: '14.00',
      tax_amount: '182.00',
      net: '1300.00',
      line_total: '1482.00',
      serials: null,
      unit_ids: [],
    },
  ],
  ...extra,
});

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('U02 purchase invoice service', () => {
  it('lists with every filter and the paging as limit/offset', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [{ ...header, lines_count: 1 }], total: 21 }, error: null });
    const list = await listPurchaseInvoices(ctx, {
      supplier_id: SUPPLIER,
      branch_id: BRANCH,
      status: 'draft',
      from: '2026-10-01',
      to: '2026-10-10',
      search: 'S-1',
      page: 2,
      pageSize: 20,
    });
    expect(list).toMatchObject({ page: 2, pageSize: 20, total: 21 });
    expect(db.rpc).toHaveBeenCalledWith('list_purchase_invoices', {
      p_supplier_id: SUPPLIER,
      p_branch_id: BRANCH,
      p_status: 'draft',
      p_from: '2026-10-01',
      p_to: '2026-10-10',
      p_search: 'S-1',
      p_limit: 20,
      p_offset: 20,
    });
  });

  it('leaves the filters out when not given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listPurchaseInvoices(ctx, { page: 1, pageSize: 50 });
    expect(db.rpc).toHaveBeenCalledWith('list_purchase_invoices', { p_limit: 50, p_offset: 0 });
  });

  it('creates with the idempotency key; optional line keys left out; no number -> ""', async () => {
    const { db, ctx } = setup();
    db.queue({ data: invoice(), error: null });
    await createPurchaseInvoice(
      ctx,
      {
        supplier_id: SUPPLIER,
        branch_id: BRANCH,
        invoice_date: '2026-10-10',
        lines: [
          { product_id: TV, quantity: 10, unit_cost: '130.00' },
          {
            product_id: PHONE,
            quantity: 1,
            unit_cost: '900.00',
            tax_class_id: CLASS,
            serials: ['SN-1'],
          },
        ],
      },
      KEY,
    );
    expect(db.rpc).toHaveBeenCalledWith('create_purchase_invoice', {
      p_supplier_id: SUPPLIER,
      p_branch_id: BRANCH,
      p_supplier_invoice_no: '',
      p_invoice_date: '2026-10-10',
      p_lines: [
        { product_id: TV, quantity: 10, unit_cost: '130.00' },
        {
          product_id: PHONE,
          quantity: 1,
          unit_cost: '900.00',
          tax_class_id: CLASS,
          serials: ['SN-1'],
        },
      ],
      p_idempotency_key: KEY,
    });
  });

  it('updates only the keys sent; a cleared supplier invoice no is null', async () => {
    const { db, ctx } = setup();
    db.queue({ data: invoice(), error: null });
    await updatePurchaseInvoice(ctx, ID, { supplier_invoice_no: null });
    expect(db.rpc).toHaveBeenLastCalledWith('update_purchase_invoice', {
      p_id: ID,
      p_changes: { supplier_invoice_no: null },
    });
    db.queue({ data: invoice(), error: null });
    await updatePurchaseInvoice(ctx, ID, {
      invoice_date: '2026-10-09',
      lines: [{ product_id: TV, quantity: 2, unit_cost: '1.00' }],
    });
    expect(db.rpc).toHaveBeenLastCalledWith('update_purchase_invoice', {
      p_id: ID,
      p_changes: {
        invoice_date: '2026-10-09',
        lines: [{ product_id: TV, quantity: 2, unit_cost: '1.00' }],
      },
    });
  });

  it('gets, approves and rejects with the right arguments', async () => {
    const { db, ctx } = setup();
    db.queue({ data: invoice(), error: null });
    expect((await getPurchaseInvoice(ctx, ID)).total).toBe('1482.00');
    expect(db.rpc).toHaveBeenLastCalledWith('get_purchase_invoice', { p_id: ID });
    db.queue({
      data: invoice({ status: 'approved', outstanding: '1482.00', approved_at: ts }),
      error: null,
    });
    expect((await approvePurchaseInvoice(ctx, ID)).outstanding).toBe('1482.00');
    expect(db.rpc).toHaveBeenLastCalledWith('approve_purchase_invoice', { p_id: ID });
    db.queue({ data: invoice({ status: 'rejected', rejected_reason: 'Wrong' }), error: null });
    await rejectPurchaseInvoice(ctx, ID, 'Wrong prices');
    expect(db.rpc).toHaveBeenLastCalledWith('reject_purchase_invoice', {
      p_id: ID,
      p_reason: 'Wrong prices',
    });
  });

  it('refuses a malformed row (money as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: invoice({ total: 1482 }), error: null });
    await expect(getPurchaseInvoice(ctx, ID)).rejects.toThrow();
  });

  it('SERIALS_REQUIRED carries the line ids; the raw message never leaks', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'SERIALS_REQUIRED: 1 line(s) need serials',
        details: JSON.stringify({ line_ids: [TV] }),
      },
    });
    const err = await approvePurchaseInvoice(ctx, ID).catch((e: unknown) => e);
    expect(err).toMatchObject({
      code: 'SERIALS_REQUIRED',
      statusCode: 422,
      details: { line_ids: [TV] },
    });
    expect((err as Error).message).not.toContain('line(s)');
  });

  it('SERIAL_TAKEN keeps its serials detail (shared mapping)', () => {
    expect(
      mapDbError({ message: 'SERIAL_TAKEN: x', details: JSON.stringify({ serials: ['SN-1'] }) }),
    ).toMatchObject({ code: 'SERIAL_TAKEN', details: { serials: ['SN-1'] } });
    expect(mapDbError({ message: 'SERIALS_REQUIRED: x', details: '{bad' })).toMatchObject({
      code: 'SERIALS_REQUIRED',
      details: undefined,
    });
  });

  it.each([
    ['PURCHASE_INVOICE_NOT_FOUND', 404],
    ['PURCHASE_INVOICE_NOT_EDITABLE', 409],
    ['SUPPLIER_INVOICE_NO_TAKEN', 409],
    ['SUPPLIER_ARCHIVED', 409],
    ['SERIALS_REQUIRED', 422],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
});
