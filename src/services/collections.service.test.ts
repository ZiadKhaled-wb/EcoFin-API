import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  getCollection,
  listContracts,
  postCollection,
  previewCollection,
  recordReceiptPrint,
  reverseCollection,
} from './collections.service';

const ID = 'a0780000-0000-4000-8000-000000000001';
const BRANCH = 'a0780000-0000-4000-8000-000000000002';
const CUSTOMER = 'a0780000-0000-4000-8000-000000000003';
const CONTRACT = 'a0780000-0000-4000-8000-000000000004';
const KEY = 'n03-key-0001';
const ts = '2026-10-16T08:00:00.000Z';

const collection = {
  id: ID,
  number: 'MAIN-PY-26-000010',
  business_date: '2026-10-16',
  paid_at: ts,
  received_by_name: 'Mona',
  branch_id: BRANCH,
  branch_name: 'Main',
  shift_id: BRANCH,
  amount: '1000.00',
  customer: { id: CUSTOMER, name: 'Nadia', phone: '01011112222' },
  payments: [
    {
      id: ID,
      number: 'MAIN-PY-26-000010',
      method: 'cash',
      amount: '1000.00',
      tendered: '1000.00',
      change: '0.00',
      reference: null,
      cash_account_id: BRANCH,
    },
  ],
  contracts: [
    {
      id: CONTRACT,
      number: 'MAIN-CT-26-000001',
      amount: '1000.00',
      status: 'active',
      allocation: {
        lines: [
          {
            seq: 1,
            due_date: '2026-11-16',
            profit: '166.67',
            principal: '833.33',
            amount: '1000.00',
            pays_off: true,
          },
        ],
        completes_contract: false,
      },
      after: { remaining: '11000.00', next_due_date: '2026-12-16', next_due_amount: '1000.00' },
    },
  ],
  reversal: null,
  receipt_prints: 0,
};
const body = {
  customer_id: CUSTOMER,
  contracts: [{ contract_id: CONTRACT, amount: '1000.00' }],
  payments: [{ method: 'cash' as const, amount: '1000.00' }],
};

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'CASHIER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('N03 collections service', () => {
  it('sends the body and the key in one call and answers the receipt', async () => {
    const { db, ctx } = setup();
    db.queue({ data: collection, error: null });
    const answer = await postCollection(ctx, body, KEY);
    expect(db.rpc).toHaveBeenCalledWith('post_collection', {
      p_body: body,
      p_idempotency_key: KEY,
    });
    expect(answer.contracts[0]?.after.remaining).toBe('11000.00');
  });

  it('maps a business error from the database to its code and detail', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'COLLECTION_EXCEEDS_REMAINING: MAIN-CT-26-000001 has 500.00 left',
        code: 'P0001',
        details: JSON.stringify({ contract_id: CONTRACT, remaining: '500.00' }),
        hint: '',
      },
    });
    await expect(postCollection(ctx, body, KEY)).rejects.toMatchObject({
      code: 'COLLECTION_EXCEEDS_REMAINING',
      statusCode: 409,
    });
  });

  it('passes the preview amount as text (money never becomes a float)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { contract: {}, due: {}, lines: [], allocation: null }, error: null });
    await expect(previewCollection(ctx, CONTRACT, '2500.10')).rejects.toThrow();
    expect(db.rpc).toHaveBeenCalledWith('preview_collection', {
      p_contract_id: CONTRACT,
      p_amount_text: '2500.10',
    });
  });

  it('lists contracts with the filters as given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], next_cursor: null }, error: null });
    expect(await listContracts(ctx, { q: 'CT', overdue: true })).toEqual({
      items: [],
      next_cursor: null,
    });
    expect(db.rpc).toHaveBeenCalledWith('list_contracts', {
      p_filters: { q: 'CT', overdue: true },
    });
  });

  it('reads, prints and reverses a receipt', async () => {
    const { db, ctx } = setup();
    db.queue({ data: collection, error: null });
    expect((await getCollection(ctx, ID)).number).toBe('MAIN-PY-26-000010');
    db.queue({
      data: { ...collection, receipt_prints: 1, print: { print_no: 1, copy: false } },
      error: null,
    });
    expect((await recordReceiptPrint(ctx, ID)).print?.copy).toBe(false);
    const reversal = {
      id: BRANCH,
      number: 'MAIN-PY-26-000011',
      reversed_at: ts,
      reversed_by_name: 'Ali',
      reason: 'wrong',
    };
    db.queue({ data: { ...collection, reversal }, error: null });
    expect((await reverseCollection(ctx, ID, { reason: 'wrong' }, KEY)).reversal?.number).toBe(
      'MAIN-PY-26-000011',
    );
    expect(db.rpc).toHaveBeenCalledWith('reverse_collection', {
      p_id: ID,
      p_body: { reason: 'wrong' },
      p_idempotency_key: KEY,
    });
  });

  it('answers COLLECTION_NOT_FOUND as 404', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'COLLECTION_NOT_FOUND', code: 'P0001', details: '', hint: '' },
    });
    await expect(getCollection(ctx, ID)).rejects.toMatchObject({
      code: 'COLLECTION_NOT_FOUND',
      statusCode: 404,
    });
  });
});
