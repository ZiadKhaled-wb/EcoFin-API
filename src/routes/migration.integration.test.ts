// M02 (D85) against the local stack (RUN_INTEGRATION=1, env as in auth.integration.test.ts), seed
// shop one. The whole path: customers, the opening-contracts file (template columns, upload,
// inspect with Arabic headers, dry run, run by the job handler), the reconciliation report (JSON and
// CSV), a wrong and the right sign-off, the reversal of a wrong batch and the refusals after a
// sign-off, plus opening cash.
import { beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import {
  AuthLoginResponse,
  ErrorResponse,
  ImportInspection,
  MigrationBatchReversal,
  MigrationReport,
  MigrationSignOff,
  MigrationSignOffList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { supabaseAdmin } from '../utils/supabase';
import {
  contractsCsv,
  ensurePolicy,
  importFile,
  newCustomer,
  uploadImportFile,
  SHOP_ONE,
  type MigrationFixture,
} from '../test/migration-fixture';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const STAMP_ID = '00000000-0000-4000-8000-0000000002c3';
const SHOP_TWO = 'd1000000-0000-0000-0000-000000000002';

describe.skipIf(!RUN)('M02 opening balances against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let owner: string;
  let cashier: string;
  let ownerTwo: string;
  let fx: MigrationFixture;
  let ip = 0;
  const nextIp = () => `198.18.17.${(++ip % 250) + 1}`;
  const call = (
    method: 'get' | 'post',
    path: string,
    token: string,
    body?: object,
    orgId?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    if (orgId) r.set('x-org-id', orgId);
    return body ? r.send(body) : r;
  };
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;

  beforeAll(async () => {
    app = createApp({ env: getEnv() });
    fx = { app, nextIp, stamp: STAMP };
    owner = await login('owner.one@ecotech.test');
    cashier = await login('cashier.one@ecotech.test');
    ownerTwo = await login('owner.two@ecotech.test');
    await ensurePolicy(fx, owner);
  });

  it('imports open contracts, reports, refuses a wrong total, signs off and then refuses a reversal', async () => {
    const a = await newCustomer(`M02 Amal ${STAMP}`);
    const b = await newCustomer(`M02 Basma ${STAMP}`);
    const bytes = contractsCsv([
      {
        ref: `M02-${STAMP}-A`,
        nid: a.nid,
        original: '5000',
        paid: '1000',
        amounts: ['1000', '1000', '1000', '1000'],
      },
      {
        ref: `M02-${STAMP}-B`,
        nid: b.nid,
        original: '3000',
        paid: '0',
        amounts: ['1500', '1500'],
        startInDays: -20,
      },
    ]);

    // Inspect with the file's own names (here the keys), then the dry run through the job path.
    const file = await uploadImportFile(fx, owner, bytes, 'open-contracts.csv');
    const inspect = await call('post', '/api/imports/inspect', owner, {
      kind: 'opening_contracts',
      file_id: file,
    });
    expect(inspect.status, JSON.stringify(inspect.body)).toBe(200);
    const parsed = ImportInspection.parse(inspect.body);
    expect(parsed.suggestion.missing_required).toEqual([]);
    expect(parsed.total_rows).toBe(6);

    const job = await importFile(fx, owner, 'opening_contracts', bytes, 'ok');
    expect(job.status, JSON.stringify(job.report)).toBe('completed');
    expect(job.report.summary?.open_total).toBe('7000.00');

    const report = MigrationReport.parse(
      (await call('get', `/api/migration/report?batch_id=${job.id}`, owner)).body,
    );
    expect(report.totals.contracts).toBe(2);
    expect(report.totals.imported_total).toBe('7000.00');
    expect(report.totals.open_now).toBe('7000.00');
    expect(report.totals.overdue_now).toBe('1500.00');
    expect(report.customers.map((c) => c.name).sort()).toEqual([
      `M02 Amal ${STAMP}`,
      `M02 Basma ${STAMP}`,
    ]);
    expect(report.batches[0]?.can_reverse).toBe(true);

    const csv = await call('get', `/api/migration/report?batch_id=${job.id}&format=csv`, owner);
    expect(csv.status).toBe(200);
    expect(csv.headers['content-type']).toContain('text/csv');
    expect(csv.headers['content-disposition']).toMatch(/migration-report-\d{4}-\d{2}-\d{2}\.csv/);
    expect(csv.text).toContain(`M02 Amal ${STAMP}`);

    // No ledger rows for the contracts; nothing in the cash ledger.
    const { count } = await supabaseAdmin
      .from('cash_movements')
      .select('id', { count: 'exact', head: true })
      .eq('source_id', job.id);
    expect(count).toBe(0);

    // A wrong total is refused with the three numbers; the right one signs.
    const wrong = await call('post', '/api/migration/sign-offs', owner, {
      expected_open_total: '6999.00',
      batch_ids: [job.id],
      note: 'Signed paper',
    });
    expect(wrong.status).toBe(409);
    expect(code(wrong)).toBe('MIGRATION_TOTAL_MISMATCH');
    expect(ErrorResponse.parse(wrong.body).error.details).toMatchObject({
      field: 'open_total',
      expected: '6999.00',
      system: '7000.00',
      difference: '-1.00',
    });
    const signed = await call('post', '/api/migration/sign-offs', owner, {
      expected_open_total: '7000',
      batch_ids: [job.id],
      note: 'Signed paper',
    });
    expect(signed.status, JSON.stringify(signed.body)).toBe(201);
    expect(MigrationSignOff.parse(signed.body).system_open_total).toBe('7000.00');
    const list = MigrationSignOffList.parse(
      (await call('get', '/api/migration/sign-offs', owner)).body,
    );
    expect(list.items.some((s) => s.batch_ids.includes(job.id))).toBe(true);

    const again = await call('post', '/api/migration/sign-offs', owner, {
      expected_open_total: '7000',
      batch_ids: [job.id],
      note: 'Signed twice',
    });
    expect(code(again)).toBe('MIGRATION_SIGNED_OFF');
    const reverse = await call('post', `/api/migration/batches/${job.id}/reverse`, owner, {
      reason: 'Too late to undo',
    });
    expect(reverse.status).toBe(409);
    expect(code(reverse)).toBe('MIGRATION_SIGNED_OFF');
  });

  it('reverses a wrong batch, leaves it out of the report and accepts the corrected file', async () => {
    const c = await newCustomer(`M02 Cairo ${STAMP}`);
    const wrongFile = contractsCsv([
      { ref: `M02-${STAMP}-C`, nid: c.nid, original: '2000', paid: '0', amounts: ['1000', '1000'] },
    ]);
    const job = await importFile(fx, owner, 'opening_contracts', wrongFile, 'wrong');
    expect(job.status).toBe('completed');

    const reversed = await call('post', `/api/migration/batches/${job.id}/reverse`, owner, {
      reason: 'Wrong customer in the file',
    });
    expect(reversed.status, JSON.stringify(reversed.body)).toBe(200);
    expect(MigrationBatchReversal.parse(reversed.body).reversed_contracts).toBe(1);
    const report = MigrationReport.parse(
      (await call('get', `/api/migration/report?customer_id=${c.id}`, owner)).body,
    );
    expect(report.totals.contracts).toBe(0);

    // The same contract number imports again.
    const again = await importFile(fx, owner, 'opening_contracts', wrongFile, 'wrong-again');
    expect(again.status).toBe('completed');
  });

  it('refuses a file with the same contract number twice and bad rows, saving nothing', async () => {
    const d = await newCustomer(`M02 Dina ${STAMP}`);
    const bytes = contractsCsv([
      { ref: `M02-${STAMP}-D`, nid: d.nid, original: '5000', paid: '0', amounts: ['1000', '1000'] },
    ]);
    const file = await uploadImportFile(fx, owner, bytes, 'unbalanced.csv');
    const dry = await call('post', '/api/imports', owner, {
      kind: 'opening_contracts',
      file_id: file,
      idempotency_key: `m02-${STAMP}-unbalanced`,
    });
    expect(dry.status).toBe(201);
    const body = dry.body as { status: string; report: { errors: { code: string }[] } };
    expect(body.status).toBe('failed');
    expect(body.report.errors.map((e) => e.code)).toEqual(['IMPORT_CONTRACT_NOT_BALANCED']);
  });

  it('imports opening cash: creates the account and posts one opening movement', async () => {
    const name = `M02 Safe ${STAMP}`;
    const bytes = Buffer.from(`account_name,kind,balance\n${name},safe,1234.50\n`);
    const job = await importFile(fx, owner, 'opening_cash', bytes, 'cash');
    expect(job.status, JSON.stringify(job.report)).toBe('completed');
    const { data } = await supabaseAdmin
      .from('cash_movements')
      .select('amount, type')
      .eq('source_id', job.id);
    expect(data).toEqual([{ amount: 1234.5, type: 'opening' }]);
    const report = MigrationReport.parse(
      (await call('get', `/api/migration/report?batch_id=${job.id}`, owner)).body,
    );
    expect(report.cash.map((x) => x.name)).toEqual([name]);
    expect(report.cash_totals.opening_posted).toBe('1234.50');
    const mismatch = await call('post', '/api/migration/sign-offs', owner, {
      expected_open_total: '0',
      expected_cash_total: '1234.00',
      batch_ids: [job.id],
      note: 'Signed paper',
    });
    expect(code(mismatch)).toBe('MIGRATION_TOTAL_MISMATCH');
    const ok = await call('post', '/api/migration/sign-offs', owner, {
      expected_open_total: '0',
      expected_cash_total: '1234.50',
      batch_ids: [job.id],
      note: 'Signed paper',
    });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    // The same file again: the account already has movements.
    const file = await uploadImportFile(fx, owner, bytes, 'cash-again.csv');
    const dry = await call('post', '/api/imports', owner, {
      kind: 'opening_cash',
      file_id: file,
      idempotency_key: `m02-${STAMP}-cash-again`,
    });
    const out = dry.body as { status: string; report: { errors: { code: string }[] } };
    expect(out.status).toBe('failed');
    expect(out.report.errors[0]?.code).toBe('CASH_ACCOUNT_HAS_MOVEMENTS');
  });

  it('safety: a cashier cannot read or write, another shop cannot reach the batches, unknown filters fail', async () => {
    expect((await call('get', '/api/migration/report', cashier)).status).toBe(403);
    expect((await call('get', '/api/migration/sign-offs', cashier)).status).toBe(403);
    expect(
      (
        await call('post', '/api/migration/sign-offs', cashier, {
          expected_open_total: '1',
          batch_ids: [STAMP_ID],
          note: 'nope',
        })
      ).status,
    ).toBe(403);
    const foreign = await call('get', '/api/migration/report', owner, undefined, SHOP_TWO);
    expect(foreign.status).toBe(403);
    const other = await call('post', `/api/migration/batches/${STAMP_ID}/reverse`, ownerTwo, {
      reason: 'not mine',
    });
    expect(other.status).toBe(404);
    expect((await call('get', '/api/migration/report?x=1', owner)).status).toBe(400);
    expect(SHOP_ONE).toBe('d1000000-0000-0000-0000-000000000001');
  });
});
