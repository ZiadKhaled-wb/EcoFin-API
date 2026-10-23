import { describe, it, expect } from 'vitest';
import { CreateQuotationBody, QuotationListQuery } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import * as q from './quotations.service';
const ID = 'a7090000-0000-4000-8000-000000000001';
function fixture() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    db: db as unknown as DbClient,
    orgId: ID,
    employeeId: ID,
    role: 'OWNER',
    userId: ID,
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
  };
  return { db, ctx };
}
describe('S09 quotations service', () => {
  it('A4 sends only priced input and never a client tenant or total', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: { id: ID, number: 'BR1-QT-26-000001' }, error: null });
    const body = CreateQuotationBody.parse({
      branch_id: ID,
      total: '999',
      lines: [{ description: 'Custom', quantity: 1, unit_price: '114.00', tax_amount: '999' }],
    });
    await q.create(ctx, body, 's09-test-key');
    expect(db.rpc).toHaveBeenCalledWith('create_quotation', {
      p_branch_id: ID,
      p_customer_id: null,
      p_valid_until: null,
      p_notes: null,
      p_lines: [
        {
          product_id: null,
          description: 'Custom',
          quantity: 1,
          unit_price: '114.00',
          discount_amount: '0',
        },
      ],
      p_idempotency_key: 's09-test-key',
    });
  });
  it('A2 scopes list through authenticated RPC with effective-status filters', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await q.list(ctx, QuotationListQuery.parse({ status: 'expired', page: 2 }));
    expect(db.rpc).toHaveBeenCalledWith(
      'list_quotations',
      expect.objectContaining({ p_status: 'expired', p_offset: 20 }),
    );
  });
  for (const [code, status] of [
    ['QUOTATION_NOT_FOUND', 404],
    ['QUOTATION_STALE', 409],
    ['QUOTATION_EXPIRED', 409],
    ['REASON_REQUIRED', 422],
    ['PRICE_OVERRIDE_REQUIRED', 403],
  ] as const)
    it('maps ' + code, async () => {
      const { db, ctx } = fixture();
      db.queue({ data: null, error: { message: code } });
      await expect(q.get(ctx, ID)).rejects.toMatchObject({ code, statusCode: status });
    });
});
