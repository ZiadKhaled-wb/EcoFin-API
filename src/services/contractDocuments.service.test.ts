import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getDocuments, recordPrint } from './contractDocuments.service';

const ID = 'a0800000-0000-4000-8000-000000000001';

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

describe('N07 contract documents service', () => {
  it('logs a print and returns the number', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { print_no: 2, copy: true }, error: null });
    expect(await recordPrint(ctx, ID, 'contract')).toEqual({ print_no: 2, copy: true });
    expect(db.rpc).toHaveBeenCalledWith('record_contract_document_print', {
      p_id: ID,
      p_document: 'contract',
    });
  });

  it('maps CONTRACT_NOT_OPEN and CONTRACT_NOT_FOUND', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'CONTRACT_NOT_OPEN: C-1',
        code: 'P0001',
        details: JSON.stringify({ contract_id: ID, status: 'completed' }),
        hint: '',
      },
    });
    await expect(recordPrint(ctx, ID, 'promissory_notes')).rejects.toMatchObject({
      code: 'CONTRACT_NOT_OPEN',
    });
    db.queue({
      data: null,
      error: { message: 'CONTRACT_NOT_FOUND', code: 'P0001', details: '', hint: '' },
    });
    await expect(getDocuments(ctx, ID)).rejects.toMatchObject({ code: 'CONTRACT_NOT_FOUND' });
    expect(db.rpc).toHaveBeenLastCalledWith('get_contract_documents', { p_id: ID });
  });

  it('never returns a malformed answer', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { nope: true }, error: null });
    await expect(getDocuments(ctx, ID)).rejects.toThrow();
  });
});
