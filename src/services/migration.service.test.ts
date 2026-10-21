import { describe, it, expect } from 'vitest';
import type { MigrationReport } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  buildReportCsv,
  getReport,
  listSignOffs,
  reverseBatch,
  signOff,
} from './migration.service';

const ID = 'a0e00000-0000-4000-8000-000000000001';
const ID2 = 'a0e00000-0000-4000-8000-000000000002';
const ts = '2026-10-22T10:00:00.000Z';
const money = {
  original_total: '12000.00',
  paid_before: '3000.00',
  imported_total: '9000.00',
  open_now: '9000.00',
  overdue_now: '0.00',
  collected_since: '0.00',
};
const report: MigrationReport = {
  as_of: '2026-10-22',
  filters: {},
  totals: { contracts: 1, customers: 1, ...money },
  customers: [
    { customer_id: ID, name: '=SUM(A1)', national_id: '**********0501', contracts: 1, ...money },
  ],
  branches: [{ branch_id: ID2, name: 'Main', contracts: 1, ...money }],
  batches: [],
  cash: [
    {
      account_id: ID2,
      name: 'Main safe',
      kind: 'safe',
      branch_id: ID2,
      branch_name: 'Main',
      opening_posted: '5000.50',
      balance_now: '5000.50',
    },
  ],
  cash_totals: { opening_posted: '5000.50', balance_now: '5000.50' },
};
const signoff = {
  id: ID,
  batch_ids: [ID2],
  expected_open_total: '9000.00',
  system_open_total: '9000.00',
  expected_cash_total: null,
  system_cash_total: '0.00',
  note: 'Signed',
  signed_file_id: null,
  signed_by: { id: ID2, name: 'Owner' },
  signed_at: ts,
};

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

describe('M02 migration service', () => {
  it('reads the report with only the filters given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: report, error: null });
    const out = await getReport(ctx, { batch_id: ID });
    expect(out.totals.contracts).toBe(1);
    expect(db.rpc).toHaveBeenCalledWith('get_migration_report', { p_filters: { batch_id: ID } });
  });

  it('builds a CSV with the totals, the customers and the cash; formulas are quoted', () => {
    const file = buildReportCsv(report, '2026-10-22');
    expect(file.filename).toBe('migration-report-2026-10-22.csv');
    expect(file.contentType).toContain('text/csv');
    const text = file.body.toString('utf8');
    expect(text.startsWith('﻿')).toBe(true);
    expect(text).toContain("'=SUM(A1)");
    expect(text).toContain('TOTAL,,1,12000.00,3000.00,9000.00,9000.00,0.00,0.00');
    expect(text).toContain('Main safe,safe,Main,5000.50,5000.50');
  });

  it('signs off and lists', async () => {
    const { db, ctx } = setup();
    db.queue({ data: signoff, error: null });
    const body = { expected_open_total: '9000', batch_ids: [ID2], note: 'Signed' };
    await signOff(ctx, body);
    expect(db.rpc).toHaveBeenCalledWith('sign_off_migration', { p_body: body });
    db.queue({ data: { items: [signoff] }, error: null });
    expect((await listSignOffs(ctx)).items).toHaveLength(1);
  });

  it('maps a total mismatch with its details; nothing raw reaches the client', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'MIGRATION_TOTAL_MISMATCH',
        code: 'P0001',
        details: JSON.stringify({
          field: 'open_total',
          expected: '29999.00',
          system: '30000.00',
          difference: '-1.00',
        }),
      },
    });
    await expect(
      signOff(ctx, { expected_open_total: '29999', batch_ids: [ID2], note: 'Signed' }),
    ).rejects.toMatchObject({
      statusCode: 409,
      code: 'MIGRATION_TOTAL_MISMATCH',
      details: { difference: '-1.00', system: '30000.00' },
    });
  });

  it('reverses a batch and maps the blockers', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'MIGRATION_SIGNED_OFF', code: 'P0001' } });
    await expect(reverseBatch(ctx, ID, { reason: 'Wrong file' })).rejects.toMatchObject({
      statusCode: 409,
      code: 'MIGRATION_SIGNED_OFF',
    });
    expect(db.rpc).toHaveBeenCalledWith('reverse_migration_batch', {
      p_id: ID,
      p_reason: 'Wrong file',
    });
    db.queue({
      data: null,
      error: {
        message: 'MIGRATION_NOT_REVERSIBLE',
        code: 'P0001',
        details: JSON.stringify({ reason: 'collection', contract_id: ID, number: 'CT-1' }),
      },
    });
    await expect(reverseBatch(ctx, ID, { reason: 'Wrong file' })).rejects.toMatchObject({
      code: 'MIGRATION_NOT_REVERSIBLE',
      details: { reason: 'collection', number: 'CT-1' },
    });
  });

  it('an unknown database error is a safe 500', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'relation "x" does not exist', code: '42P01' } });
    await expect(getReport(ctx, {})).rejects.toMatchObject({ statusCode: 500 });
  });
});
