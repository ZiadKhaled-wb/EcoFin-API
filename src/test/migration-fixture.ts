// M02 (D85): helpers for the integration tests that need a migrated batch against the local stack
// (seed shop one): a policy, customers, an opening-contracts CSV and the whole import path
// (upload, dry run, run, the job handler as the worker calls it).
import pino from 'pino';
import request from 'supertest';
import { ImportJob } from '@ziadkhaled-wb/contracts';
import type { createApp } from '../app';
import { importApply } from '../jobs/handlers/importApply';
import { supabaseAdmin } from '../utils/supabase';

export const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';

export interface MigrationFixture {
  app: ReturnType<typeof createApp>;
  nextIp: () => string;
  stamp: number;
}

export interface FixtureContract {
  ref: string;
  nid: string;
  original: string;
  paid: string;
  /** One installment per amount, 30 days apart from `startInDays` (negative = already late). */
  amounts: string[];
  startInDays?: number;
}

let nidCounter = 0;
/** A fresh valid national ID (born 1990-01-01, governorate 01). */
export function freshNid(): string {
  nidCounter += 1;
  const tail = String((Date.now() + nidCounter) % 100000).padStart(5, '0');
  return `2900101${'01'}${tail}`;
}

export async function ensurePolicy(fx: MigrationFixture, token: string): Promise<void> {
  const current = await request(fx.app)
    .get('/api/settings')
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`);
  if ((current.body as { installment_policy: unknown }).installment_policy) return;
  const made = await request(fx.app)
    .post('/api/settings/installment-policies')
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`)
    .send({ grace_days: 0 });
  if (made.status !== 201) throw new Error(`policy not published: ${JSON.stringify(made.body)}`);
}

/** A customer of shop one with a national ID (the import matches on it). */
export async function newCustomer(name: string): Promise<{ id: string; nid: string }> {
  const nid = freshNid();
  const { data, error } = await supabaseAdmin
    .from('customers')
    .insert({
      organization_id: SHOP_ONE,
      full_name: name,
      phones: [`010${nid.slice(-8)}`],
      national_id: nid,
    })
    .select('id')
    .single();
  if (error) throw new Error(error.message);
  return { id: data.id, nid };
}

const isoDay = (offset: number): string =>
  new Date(Date.now() + offset * 86_400_000).toISOString().slice(0, 10);

export function contractsCsv(contracts: readonly FixtureContract[]): Buffer {
  const lines = [
    'contract_ref,customer_national_id,contract_date,original_total,paid_before,due_date,amount',
  ];
  for (const c of contracts) {
    c.amounts.forEach((amount, i) => {
      const due = isoDay((c.startInDays ?? 30) + 30 * i);
      lines.push(`${c.ref},${c.nid},2025-01-15,${c.original},${c.paid},${due},${amount}`);
    });
  }
  return Buffer.from(lines.join('\n') + '\n');
}

export async function uploadImportFile(
  fx: MigrationFixture,
  token: string,
  bytes: Buffer,
  name: string,
): Promise<string> {
  const res = await request(fx.app)
    .post('/api/files')
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`)
    .field('purpose', 'import')
    .attach('file', bytes, name);
  if (res.status !== 201) throw new Error(`upload failed: ${JSON.stringify(res.body)}`);
  return (res.body as { id: string }).id;
}

/** What the worker does for a queued import.apply job. */
export async function work(importJobId: string): Promise<void> {
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

/** Dry run, run and work for a file of kind `kind`; returns the job as the API shows it. */
export async function importFile(
  fx: MigrationFixture,
  token: string,
  kind: 'opening_contracts' | 'opening_cash',
  bytes: Buffer,
  tag: string,
): Promise<ImportJob> {
  const file = await uploadImportFile(fx, token, bytes, `${tag}.csv`);
  const dry = await request(fx.app)
    .post('/api/imports')
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`)
    .send({ kind, file_id: file, idempotency_key: `m02-${fx.stamp}-${tag}-dry` });
  if (dry.status !== 201) throw new Error(`dry run failed: ${JSON.stringify(dry.body)}`);
  const job = ImportJob.parse(dry.body);
  if (job.status !== 'validated') throw new Error(`not validated: ${JSON.stringify(job.report)}`);
  const run = await request(fx.app)
    .post(`/api/imports/${job.id}/run`)
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`)
    .send({ idempotency_key: `m02-${fx.stamp}-${tag}-run` });
  if (run.status !== 202) throw new Error(`run failed: ${JSON.stringify(run.body)}`);
  await work(job.id);
  const done = await request(fx.app)
    .get(`/api/imports/${job.id}`)
    .set('X-Forwarded-For', fx.nextIp())
    .set('Authorization', `Bearer ${token}`);
  return ImportJob.parse(done.body);
}
