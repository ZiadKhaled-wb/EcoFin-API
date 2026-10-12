import { describe, expect, it, vi } from 'vitest';
import type { Request, Response } from 'express';
import { SalesHistoryQuery } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getSaleDetails, searchSales, voidSale } from './salesHistory.service';
import { voidSale as voidController } from '../controllers/salesHistory.controller';
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
describe('S07 history and void service', () => {
  it('passes validated filters without client tenant data and preserves the total on an empty later page', async () => {
    const { db, ctx } = fixture();
    const row = {
      id: ID,
      number: 'SL',
      issued_at: '2026-10-12T10:00:00Z',
      business_date: '2026-10-12',
      branch: { id: ID, name: 'Main' },
      cashier: { id: ID, name: 'Owner' },
      customer: null,
      total: '250.00',
      status: 'completed',
      items_count: 1,
      total_count: 9,
    };
    db.queue({ data: [], error: null }, { data: [row], error: null });
    expect(await searchSales(ctx, SalesHistoryQuery.parse({ q: 'SN', page: 2 }))).toEqual({
      items: [],
      total: 9,
    });
    expect(db.rpc).toHaveBeenNthCalledWith(1, 'search_sales', {
      p_query: 'SN',
      p_limit: 20,
      p_offset: 20,
    });
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'search_sales', {
      p_query: 'SN',
      p_limit: 1,
      p_offset: 0,
    });
  });
  it('posts one caller-JWT RPC with the idempotency key', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: { return_id: ID, number: 'RT' }, error: null });
    expect(await voidSale(ctx, ID, 'Duplicate', 's07-key-001')).toEqual({
      return_id: ID,
      number: 'RT',
    });
    expect(db.rpc).toHaveBeenCalledWith('void_sale', {
      p_sale_id: ID,
      p_reason: 'Duplicate',
      p_idempotency_key: 's07-key-001',
    });
  });
  it('refuses a missing Idempotency-Key before any database write', async () => {
    const { db, ctx } = fixture();
    const req = {
      ctx,
      params: { id: ID },
      headers: {},
      body: { reason: 'Duplicate' },
    } as unknown as Request;
    await expect(
      voidController(req, { status: vi.fn(), json: vi.fn() } as unknown as Response),
    ).rejects.toMatchObject({ name: 'ZodError' });
    expect(db.rpc).not.toHaveBeenCalled();
  });
  it.each([
    ['SALE_NOT_FOUND', 404],
    ['VOID_NOT_SAME_DAY', 409],
    ['VOID_SHIFT_CLOSED', 409],
    ['VOID_HAS_RETURNS', 409],
    ['ALREADY_VOIDED', 409],
    ['VOID_HAS_CLAIMS', 409],
    ['VOID_HAS_CONTRACT', 409],
    ['VOID_FISCALIZED', 409],
    ['REASON_REQUIRED', 400],
  ])('maps %s to %s without leaking database details', async (code, statusCode) => {
    const { db, ctx } = fixture();
    db.queue({ data: null, error: { message: code + ': private data' } });
    await expect(voidSale(ctx, ID, 'Duplicate', 's07-key-001')).rejects.toMatchObject({
      code,
      statusCode,
    });
  });
  it('a foreign or inaccessible detail is not found', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: null, error: { message: 'SALE_NOT_FOUND' } });
    await expect(getSaleDetails(ctx, ID)).rejects.toMatchObject({
      code: 'SALE_NOT_FOUND',
      statusCode: 404,
    });
  });
});
