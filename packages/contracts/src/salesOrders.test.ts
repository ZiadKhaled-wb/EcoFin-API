import { describe, expect, it } from 'vitest';
import { errorCodeHttpStatus } from './errors.js';
import {
  CancelSalesOrderBody,
  CreateSalesOrderBody,
  OrderDepositBody,
  OrderFromQuotationBody,
} from './salesOrders.js';

const ID = 'd2000000-0000-4000-8000-000000000011';
describe('S10 contracts', () => {
  it('O1 keeps decimal line input and drops client totals', () => {
    const body = CreateSalesOrderBody.parse({
      branch_id: ID,
      customer_id: ID,
      total: '999',
      lines: [{ product_id: ID, quantity: 2, unit_price: '120.00', line_total: '999' }],
    });
    expect(body).not.toHaveProperty('total');
    expect(body.lines[0]).not.toHaveProperty('line_total');
    expect(body.lines[0]).toMatchObject({
      unit_price: '120.00',
      discount_amount: '0',
      fulfilment: 'from_stock',
    });
    const numeric = { branch_id: ID, customer_id: ID, lines: [{ product_id: ID, quantity: 1 }] };
    expect(
      CreateSalesOrderBody.safeParse({
        ...numeric,
        lines: [{ ...numeric.lines[0], unit_price: 1 }],
      }).success,
    ).toBe(false);
    expect(CreateSalesOrderBody.safeParse({ ...numeric, lines: [] }).success).toBe(false);
  });
  it('O2 keys quote line options by line number', () => {
    expect(
      OrderFromQuotationBody.parse({ line_options: { '2': { fulfilment: 'to_order' } } })
        .line_options['2'],
    ).toMatchObject({ fulfilment: 'to_order' });
    expect(OrderFromQuotationBody.safeParse({ line_options: { x: {} } }).success).toBe(false);
  });
  it('O8 deposits use the S02 payment lines; O9 refunds may be empty', () => {
    expect(OrderDepositBody.safeParse({ payments: [] }).success).toBe(false);
    expect(
      OrderDepositBody.safeParse({ payments: [{ method: 'cash', amount: '100.00' }] }).success,
    ).toBe(true);
    expect(CancelSalesOrderBody.parse({ reason: ' changed mind ' })).toEqual({
      reason: 'changed mind',
      refund: [],
    });
    expect(CancelSalesOrderBody.safeParse({ reason: 'ab' }).success).toBe(false);
  });
  it('maps the S10 codes to the agreed statuses', () => {
    expect(errorCodeHttpStatus).toMatchObject({
      ORDER_NOT_FOUND: 404,
      ORDER_NOT_OPEN: 409,
      DEPOSIT_EXCEEDS_BALANCE: 409,
      REFUND_MUST_EQUAL_DEPOSITS: 422,
      ORDER_LINES_INVALID: 422,
      REASON_REQUIRED: 400,
    });
    expect(errorCodeHttpStatus).not.toHaveProperty('PO_NOT_FOUND');
  });
});
