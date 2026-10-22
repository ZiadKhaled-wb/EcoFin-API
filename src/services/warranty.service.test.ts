import { describe, it, expect, vi } from 'vitest';
import type { Request, Response } from 'express';
import { WarrantyLookupQuery, WarrantyClaimsQuery } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import * as w from './warranty.service';
import {
  open as openController,
  lookup as lookupController,
} from '../controllers/warranty.controller';
const ID = 'a7070000-0000-4000-8000-000000000001';
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

describe('S12 warranty service', () => {
  it('lookup accepts only one key and has no client tenant', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: { items: [] }, error: null });
    expect(await w.lookup(ctx, WarrantyLookupQuery.parse({ serial: ' A ' }))).toEqual({
      items: [],
    });
    expect(db.rpc).toHaveBeenCalledWith('warranty_lookup', { p_serial: 'A' });
  });
  it('lists literal false and paging with a stable total', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: { items: [], total: 9 }, error: null });
    expect(
      await w.list(ctx, WarrantyClaimsQuery.parse({ out_of_warranty: 'false', page: 2 })),
    ).toEqual({ items: [], total: 9 });
    expect(db.rpc).toHaveBeenCalledWith('list_warranty_claims', {
      p_out_of_warranty: false,
      p_limit: 20,
      p_offset: 20,
    });
  });
  it('opens through caller JWT with the required key', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: { claim_id: ID, number: 'WC', out_of_warranty: true }, error: null });
    expect(
      await w.open(
        ctx,
        { sale_line_id: ID, issue: 'Broken', condition: 'Scratched' },
        's12-key-0001',
      ),
    ).toMatchObject({ claim_id: ID });
    expect(db.rpc).toHaveBeenCalledWith('open_warranty_claim', {
      p_sale_line_id: ID,
      p_unit_id: null,
      p_issue: 'Broken',
      p_condition: 'Scratched',
      p_idempotency_key: 's12-key-0001',
    });
  });
  it('missing Idempotency-Key fails before writes', async () => {
    const { ctx, db } = fixture();
    await expect(
      openController(
        {
          ctx,
          headers: {},
          body: { sale_line_id: ID, issue: 'Broken', condition: 'Scratched' },
        } as unknown as Request,
        { status: vi.fn(), json: vi.fn() } as unknown as Response,
      ),
    ).rejects.toMatchObject({ name: 'ZodError' });
    expect(db.rpc).not.toHaveBeenCalled();
  });
  it('missing or multiple lookup keys return LOOKUP_ONE_KEY before DB', async () => {
    for (const query of [{}, { serial: 'A', phone: '010' }]) {
      const { ctx, db } = fixture();
      await expect(
        lookupController(
          { ctx, query } as unknown as Request,
          { json: vi.fn() } as unknown as Response,
        ),
      ).rejects.toMatchObject({ code: 'LOOKUP_ONE_KEY', statusCode: 400 });
      expect(db.rpc).not.toHaveBeenCalled();
    }
  });
  it.each([
    ['LOOKUP_ONE_KEY', 400],
    ['SALE_LINE_NOT_FOUND', 404],
    ['CLAIM_UNIT_MISMATCH', 400],
    ['CLAIM_ALREADY_OPEN', 409],
    ['CLAIM_QTY_EXCEEDED', 409],
    ['CLAIM_BAD_TRANSITION', 409],
    ['OUT_OF_WARRANTY_NEEDS_MANAGER', 403],
    ['CLAIM_REFUND_NEEDS_RETURN', 409],
    ['REPLACEMENT_UNIT_INVALID', 400],
  ])('maps %s to %s', async (code, statusCode) => {
    const { ctx, db } = fixture();
    db.queue({ data: null, error: { message: code + ': private data' } });
    await expect(w.move(ctx, ID, { to: 'replaced', note: 'Replacement' })).rejects.toMatchObject({
      code,
      statusCode,
    });
  });
  it('foreign claim detail is not found', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: null, error: { message: 'NOT_FOUND' } });
    await expect(w.get(ctx, ID)).rejects.toMatchObject({ code: 'NOT_FOUND', statusCode: 404 });
  });
  it('S05: refund answers what the return form opens with; a closed claim stays 409', async () => {
    const { ctx, db } = fixture();
    const target = { claim_id: ID, sale_id: ID, sale_line_id: ID, unit_id: null };
    db.queue({ data: target, error: null });
    expect(await w.refund(ctx, ID)).toEqual(target);
    db.queue({ data: null, error: { message: 'CLAIM_REFUND_NEEDS_RETURN: the claim is closed' } });
    await expect(w.refund(ctx, ID)).rejects.toMatchObject({
      code: 'CLAIM_REFUND_NEEDS_RETURN',
      statusCode: 409,
    });
  });
});
