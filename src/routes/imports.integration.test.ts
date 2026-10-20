// M01 (D83) against the local stack (RUN_INTEGRATION=1, env as in auth.integration.test.ts), with the
// seed shop one (plan retail_pro: customers and serials). The whole path: template, upload (F14),
// inspect, dry run with errors (nothing saved, an errors CSV linked), the fixed file with the
// shop's own column names, the run (the job handler is called as the worker would), a re-import that
// changes nothing, opening stock from an xlsx, and the safety cases.
import ExcelJS from 'exceljs';
import pino from 'pino';
import { beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import {
  AuthLoginResponse,
  ErrorResponse,
  FileUrlResponse,
  ImportInspection,
  ImportJob,
  ImportListResponse,
  IMPORT_COLUMNS,
  IMPORT_KINDS,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { importApply } from '../jobs/handlers/importApply';
import { getEnv } from '../utils/env';
import { supabaseAdmin } from '../utils/supabase';
import { buildImportTemplate } from '../services/imports/files';
import { readImportTable, toFieldRows } from '../services/imports/parse';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const BR1 = 'd2000000-0000-0000-0000-000000000011';

describe.skipIf(!RUN)('M01 import against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let owner: string;
  let cashier: string;
  let ownerTwo: string;
  let ip = 0;
  const nextIp = () => `198.18.16.${(++ip % 250) + 1}`;
  const key = (tag: string) => `m01-${STAMP}-${tag}`;
  const sku = (tag: string) => `M01-${STAMP}-${tag}`.toUpperCase();

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

  /** Uploads bytes as an import file (F14); returns its id. */
  async function upload(token: string, bytes: Buffer, name: string): Promise<string> {
    const res = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token)
      .field('purpose', 'import')
      .attach('file', bytes, name);
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return (res.body as { id: string }).id;
  }
  async function dryRun(token: string, body: object): Promise<ImportJob> {
    const res = await call('post', '/api/imports', token, body);
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return ImportJob.parse(res.body);
  }
  /** What the worker does for a queued import.apply job. */
  async function work(importJobId: string) {
    await importApply(supabaseAdmin)(
      {
        id: importJobId,
        organizationId: SHOP_ONE,
        type: 'import.apply',
        payload: { import_job_id: importJobId },
        attempt: 1,
        maxAttempts: 3,
      },
      pino({ level: 'silent' }),
    );
  }
  async function runAndWork(job: ImportJob, tag: string): Promise<ImportJob> {
    const run = await call('post', `/api/imports/${job.id}/run`, owner, {
      idempotency_key: key(`run-${tag}`),
    });
    expect(run.status, JSON.stringify(run.body)).toBe(202);
    expect(ImportJob.parse(run.body).status).toBe('importing');
    await work(job.id);
    const done = await call('get', `/api/imports/${job.id}`, owner);
    expect(done.status).toBe(200);
    return ImportJob.parse(done.body);
  }
  const productCount = async (like: string) => {
    const { count, error } = await supabaseAdmin
      .from('products')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', SHOP_ONE)
      .like('sku', like);
    expect(error).toBeNull();
    return count ?? 0;
  };

  beforeAll(async () => {
    app = createApp({ env: getEnv() });
    owner = await login('owner.one@ecotech.test');
    cashier = await login('cashier.one@ecotech.test');
    ownerTwo = await login('owner.two@ecotech.test');
  });

  it('templates download as xlsx and csv for every kind, and read back through the importer', async () => {
    for (const kind of IMPORT_KINDS) {
      const x = await call('get', `/api/imports/templates/${kind}`, owner).buffer().parse(binary);
      expect(x.status).toBe(200);
      expect(String(x.headers['content-disposition'])).toContain(
        `ecofin-import-${kind.replaceAll('_', '-')}-template.xlsx`,
      );
      const table = await readImportTable(x.body as Buffer);
      expect(table.headers).toEqual(IMPORT_COLUMNS[kind].map((c) => c.key));
      const c = await call('get', `/api/imports/templates/${kind}?format=csv`, owner);
      expect(c.status).toBe(200);
      expect(String(c.headers['content-type'])).toContain('text/csv');
    }
    expect((await call('get', '/api/imports/templates/nope', owner)).status).toBe(400);
    expect((await call('get', '/api/imports/templates/products', cashier)).status).toBe(403);
  });

  it('Done when: a products file with 3 errors lists all 3, saves nothing and refuses the run', async () => {
    const csv = [
      'sku,name_ar,cash_price,category',
      `${sku('E1')},سامسونج,9000,Phones > Samsung`,
      `${sku('E2')},,100,`,
      `${sku('E3')},كابل,"1,500",`,
      `${sku('E1')},مكرر,5,`,
    ].join('\r\n');
    const file = await upload(owner, Buffer.from(csv), 'products_errors.csv');
    const job = await dryRun(owner, {
      kind: 'products',
      file_id: file,
      idempotency_key: key('errors'),
    });
    expect(job.status).toBe('failed');
    expect(job.report.errors.map((e) => `${e.row}:${e.column}:${e.code}`)).toEqual([
      '3:name_ar:IMPORT_REQUIRED',
      '4:cash_price:IMPORT_INVALID_VALUE',
      '5:sku:IMPORT_DUPLICATE_ROW',
    ]);
    expect(job.report.will_create_categories).toEqual(['Phones', 'Phones > Samsung']);
    expect(await productCount(`M01-${STAMP}-E%`)).toBe(0);

    // The errors CSV is linked and downloadable through the files API.
    expect(job.result_file_id).not.toBeNull();
    const link = await call('get', `/api/files/${job.result_file_id}/url`, owner);
    expect(link.status, JSON.stringify(link.body)).toBe(200);
    const signed = FileUrlResponse.parse(link.body).url;
    const downloaded = await fetch(signed);
    expect(downloaded.status).toBe(200);
    expect(await downloaded.text()).toContain('3,name_ar,IMPORT_REQUIRED');

    // Done when: the import button is refused.
    const run = await call('post', `/api/imports/${job.id}/run`, owner, {
      idempotency_key: key('run-errors'),
    });
    expect(run.status).toBe(409);
    expect(ErrorResponse.parse(run.body).error).toMatchObject({
      code: 'IMPORT_NOT_VALIDATED',
      details: { status: 'failed' },
    });
    // Same key again: the same job, not a second one.
    const again = await dryRun(owner, {
      kind: 'products',
      file_id: file,
      idempotency_key: key('errors'),
    });
    expect(again.id).toBe(job.id);

    const cancelled = await call('post', `/api/imports/${job.id}/cancel`, owner);
    expect(cancelled.status).toBe(200);
    expect(ImportJob.parse(cancelled.body).status).toBe('cancelled');
  });

  it('a shop’s own column names are matched, the import runs and a re-import changes nothing', async () => {
    const csv = [
      'Item Code;Product Name;Price;Brand;Is Serialized',
      `${sku('P1')};هاتف سامسونج;9000;Samsung;yes`,
      `${sku('P2')};كابل شاحن;50.50;;no`,
      `${sku('P3')};شاحن;250;;`,
    ].join('\r\n');
    const bytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(csv, 'utf8')]);
    const file = await upload(owner, bytes, 'my_products.csv');

    const inspected = await call('post', '/api/imports/inspect', owner, {
      kind: 'products',
      file_id: file,
    });
    expect(inspected.status, JSON.stringify(inspected.body)).toBe(200);
    const info = ImportInspection.parse(inspected.body);
    expect(info.headers).toEqual(['Item Code', 'Product Name', 'Price', 'Brand', 'Is Serialized']);
    expect(info.suggestion.mapping).toEqual({
      sku: 'Item Code',
      name_ar: 'Product Name',
      cash_price: 'Price',
      is_serialized: 'Is Serialized',
    });
    expect(info.suggestion.unmapped_headers).toEqual(['Brand']);
    expect(info.total_rows).toBe(3);

    const job = await dryRun(owner, {
      kind: 'products',
      file_id: file,
      mapping: info.suggestion.mapping,
      idempotency_key: key('p-1'),
    });
    expect(job.status, JSON.stringify(job.report.errors)).toBe('validated');
    expect(job.report.actions).toEqual({ create: 3, update: 0, unchanged: 0 });
    expect(job.report.warnings.map((w) => w.column)).toEqual(['Brand']);
    expect(await productCount(`M01-${STAMP}-P%`)).toBe(0);

    const done = await runAndWork(job, 'p-1');
    expect(done.status, JSON.stringify(done.report)).toBe('completed');
    expect(done.rows_ok).toBe(3);
    expect(await productCount(`M01-${STAMP}-P%`)).toBe(3);
    const { data } = await supabaseAdmin
      .from('products')
      .select('sku, name_ar, cash_price, is_serialized, barcode')
      .eq('organization_id', SHOP_ONE)
      .like('sku', `M01-${STAMP}-P%`)
      .order('sku');
    expect(data?.map((p) => [p.sku, p.name_ar, Number(p.cash_price), p.is_serialized])).toEqual([
      [sku('P1'), 'هاتف سامسونج', 9000, true],
      [sku('P2'), 'كابل شاحن', 50.5, false],
      [sku('P3'), 'شاحن', 250, false],
    ]);
    expect(data?.every((p) => /^2\d{12}$/.test(p.barcode ?? ''))).toBe(true);

    // The same file again: nothing new.
    const second = await dryRun(owner, {
      kind: 'products',
      file_id: file,
      idempotency_key: key('p-2'),
    });
    expect(second.report.actions).toEqual({ create: 0, update: 0, unchanged: 3 });

    // The history shows both, newest first.
    const list = await call('get', '/api/imports?kind=products&limit=5', owner);
    expect(list.status).toBe(200);
    const items = ImportListResponse.parse(list.body).items;
    expect(items[0]?.id).toBe(second.id);
    expect(items.find((i) => i.id === job.id)?.status).toBe('completed');
  });

  it('opening stock from an xlsx: stock equals the file; a second file changes one quantity', async () => {
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('Stock');
    ws.addRow(['SKU', 'Qty', 'Cost', 'IMEI']);
    ws.addRow([sku('P2'), 10, 30, null]);
    ws.addRow([sku('P3'), 4, 40.5, null]);
    ws.addRow([sku('P1'), null, 7000, `m01-${STAMP}-a`]);
    ws.addRow([sku('P1'), null, 7100, `M01-${STAMP}-B`]);
    const bytes = Buffer.from(await wb.xlsx.writeBuffer());
    const file = await upload(owner, bytes, 'opening.xlsx');

    const job = await dryRun(owner, {
      kind: 'opening_stock',
      file_id: file,
      branch_id: BR1,
      idempotency_key: key('os-1'),
    });
    expect(job.status, JSON.stringify(job.report.errors)).toBe('validated');
    expect(job.report.actions.create).toBe(4);
    const done = await runAndWork(job, 'os-1');
    expect(done.status, JSON.stringify(done.report)).toBe('completed');

    const level = async (s: string) => {
      const { data: p } = await supabaseAdmin
        .from('products')
        .select('id, avg_cost')
        .eq('organization_id', SHOP_ONE)
        .eq('sku', s)
        .single();
      const { data: l } = await supabaseAdmin
        .from('stock_levels')
        .select('on_hand')
        .eq('organization_id', SHOP_ONE)
        .eq('product_id', p?.id ?? '')
        .eq('branch_id', BR1)
        .eq('stock_state', 'sellable')
        .maybeSingle();
      return { onHand: l?.on_hand ?? 0, avgCost: Number(p?.avg_cost) };
    };
    expect(await level(sku('P2'))).toEqual({ onHand: 10, avgCost: 30 });
    expect(await level(sku('P3'))).toEqual({ onHand: 4, avgCost: 40.5 });
    expect(await level(sku('P1'))).toEqual({ onHand: 2, avgCost: 7050 });
    const { data: movements } = await supabaseAdmin
      .from('stock_movements')
      .select('type, source_type, source_id')
      .eq('organization_id', SHOP_ONE)
      .eq('source_id', job.id);
    expect(movements).toHaveLength(4);
    expect(movements?.every((m) => m.type === 'opening' && m.source_type === 'import')).toBe(true);

    // Raise P2 from 10 to 12: one +2 movement.
    const wb2 = new ExcelJS.Workbook();
    const ws2 = wb2.addWorksheet('Stock');
    ws2.addRow(['SKU', 'Qty', 'Cost']);
    ws2.addRow([sku('P2'), 12, 30]);
    const file2 = await upload(owner, Buffer.from(await wb2.xlsx.writeBuffer()), 'opening2.xlsx');
    const job2 = await dryRun(owner, {
      kind: 'opening_stock',
      file_id: file2,
      branch_id: BR1,
      idempotency_key: key('os-2'),
    });
    expect(job2.report.actions).toEqual({ create: 0, update: 1, unchanged: 0 });
    expect((await runAndWork(job2, 'os-2')).status).toBe('completed');
    expect((await level(sku('P2'))).onHand).toBe(12);
  });

  it('safety: other shops, other roles, unreadable files, too many rows, a bad mapping', async () => {
    const file = await upload(owner, Buffer.from('name\r\nM01 Safe Co\r\n'), 'suppliers.csv');
    const job = await dryRun(owner, {
      kind: 'suppliers',
      file_id: file,
      idempotency_key: key('s-1'),
    });
    expect(job.status).toBe('validated');

    // A cashier: 403 everywhere in the import area.
    expect(
      (
        await call('post', '/api/imports', cashier, {
          kind: 'suppliers',
          file_id: file,
          idempotency_key: key('c-1'),
        })
      ).status,
    ).toBe(403);
    expect(
      (await call('post', '/api/imports/inspect', cashier, { kind: 'suppliers', file_id: file }))
        .status,
    ).toBe(403);
    expect(
      (await call('post', `/api/imports/${job.id}/run`, cashier, { idempotency_key: key('c-2') }))
        .status,
    ).toBe(403);
    expect((await call('post', `/api/imports/${job.id}/cancel`, cashier)).status).toBe(403);
    const read = await call('get', `/api/imports/${job.id}`, cashier);
    expect(read.status).toBe(403);
    expect((await call('get', '/api/imports', cashier)).status).toBe(403);

    // Another shop: neither the job nor the file exists for it.
    const otherJob = await call('get', `/api/imports/${job.id}`, ownerTwo);
    expect(otherJob.status).toBe(404);
    expect(code(otherJob)).toBe('IMPORT_JOB_NOT_FOUND');
    expect(
      code(
        await call('post', `/api/imports/${job.id}/run`, ownerTwo, { idempotency_key: key('o-1') }),
      ),
    ).toBe('IMPORT_JOB_NOT_FOUND');
    expect(code(await call('post', `/api/imports/${job.id}/cancel`, ownerTwo))).toBe(
      'IMPORT_JOB_NOT_FOUND',
    );
    const otherFile = await call('post', '/api/imports', ownerTwo, {
      kind: 'suppliers',
      file_id: file,
      idempotency_key: key('o-2'),
    });
    expect(otherFile.status).toBe(404);
    expect(code(otherFile)).toBe('FILE_NOT_FOUND');
    const theirList = ImportListResponse.parse((await call('get', '/api/imports', ownerTwo)).body);
    expect(theirList.items.some((i) => i.id === job.id)).toBe(false);

    // A zip that is not a workbook: unreadable.
    const broken = await upload(
      owner,
      Buffer.concat([Buffer.from([0x50, 0x4b, 0x03, 0x04]), Buffer.alloc(300, 1)]),
      'broken.xlsx',
    );
    const unreadable = await call('post', '/api/imports/inspect', owner, {
      kind: 'suppliers',
      file_id: broken,
    });
    expect(unreadable.status).toBe(422);
    expect(code(unreadable)).toBe('IMPORT_FILE_UNREADABLE');

    // 5,001 rows.
    const big = ['name', ...Array.from({ length: 5001 }, (_, i) => `S${i}`)].join('\n');
    const bigFile = await upload(owner, Buffer.from(big), 'big.csv');
    const tooMany = await call('post', '/api/imports/inspect', owner, {
      kind: 'suppliers',
      file_id: bigFile,
    });
    expect(tooMany.status).toBe(413);
    expect(code(tooMany)).toBe('IMPORT_TOO_MANY_ROWS');

    // A sheet that does not exist (a CSV has none), missing columns, a bad mapping.
    expect(
      code(
        await call('post', '/api/imports/inspect', owner, {
          kind: 'suppliers',
          file_id: file,
          sheet: 'Nope',
        }),
      ),
    ).toBe('IMPORT_SHEET_NOT_FOUND');
    const noCols = await upload(owner, Buffer.from('foo,bar\r\n1,2\r\n'), 'nocols.csv');
    const missing = await call('post', '/api/imports', owner, {
      kind: 'suppliers',
      file_id: noCols,
      idempotency_key: key('m-1'),
    });
    expect(missing.status).toBe(422);
    expect(ErrorResponse.parse(missing.body).error).toMatchObject({
      code: 'IMPORT_MISSING_COLUMNS',
      details: { columns: ['name'], headers: ['foo', 'bar'] },
    });
    const badMap = await call('post', '/api/imports', owner, {
      kind: 'suppliers',
      file_id: file,
      mapping: { name: 'Nope' },
      idempotency_key: key('m-2'),
    });
    expect(badMap.status).toBe(422);
    expect(code(badMap)).toBe('IMPORT_MAPPING_INVALID');
    // Body rules: opening stock needs a branch, other kinds refuse one, no org id.
    expect(
      (
        await call('post', '/api/imports', owner, {
          kind: 'opening_stock',
          file_id: file,
          idempotency_key: key('b-1'),
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await call('post', '/api/imports', owner, {
          kind: 'suppliers',
          file_id: file,
          branch_id: BR1,
          idempotency_key: key('b-2'),
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await call('post', '/api/imports', owner, {
          kind: 'suppliers',
          file_id: file,
          organization_id: SHOP_ONE,
          idempotency_key: key('b-3'),
        })
      ).status,
    ).toBe(400);

    // The worker marks a job whose every attempt failed outside the database as failed.
    const run = await call('post', `/api/imports/${job.id}/run`, owner, {
      idempotency_key: key('s-run'),
    });
    expect(run.status).toBe(202);
    const rerun = await call('post', `/api/imports/${job.id}/run`, owner, {
      idempotency_key: key('s-run'),
    });
    expect(rerun.status, 'the same key on an importing job answers it again').toBe(202);
    await supabaseAdmin.rpc('jobs_import_fail', {
      p_job_id: job.id,
      p_reason: 'The file could not be read.',
    });
    const failed = ImportJob.parse((await call('get', `/api/imports/${job.id}`, owner)).body);
    expect(failed.status).toBe('failed');
    expect(failed.report.failure).toBe('The file could not be read.');
  });

  it('the template example rows of every kind import without errors (keys agree with SQL)', async () => {
    // One valid row per kind from the contract examples, so a key added to one side only fails here.
    const examples = {
      suppliers: {
        name: `M01 Example ${STAMP}`,
        phone: '',
        tax_registration_no: '',
        address: 'Cairo',
        payment_terms_days: '30',
        notes: '',
      },
      customers: {
        full_name: `M01 Customer ${STAMP}`,
        phones: '01055555555',
        city: 'Cairo',
        job: 'Teacher',
        employer: 'School',
        monthly_income: '5000',
        is_business: 'no',
        notes: 'x',
        address: 'a',
      },
    } as const;
    for (const kind of ['suppliers', 'customers'] as const) {
      const header = Object.keys(examples[kind]).join(',');
      const row = Object.values(examples[kind]).join(',');
      const file = await upload(owner, Buffer.from(`${header}\r\n${row}\r\n`), `${kind}.csv`);
      const job = await dryRun(owner, { kind, file_id: file, idempotency_key: key(`ex-${kind}`) });
      expect(job.status, JSON.stringify(job.report.errors)).toBe('validated');
    }
    // And the field keys the contract lists are exactly what the importer reads from a template.
    const template = await buildImportTemplate('products', 'csv');
    const table = await readImportTable(template.body);
    expect(toFieldRows('products', table, {})).toEqual([]);
  });
});

/** supertest: keep the body as a Buffer. */
function binary(res: request.Response, done: (err: Error | null, body: Buffer) => void): void {
  const chunks: Buffer[] = [];
  res.on('data', (c: Buffer) => chunks.push(c));
  res.on('end', () => done(null, Buffer.concat(chunks)));
}
