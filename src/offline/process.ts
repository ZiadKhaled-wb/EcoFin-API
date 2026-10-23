// server/src/offline/process.ts
//
// S08 (D10). The 'offline.process' job (F13), queued by the database when a device's offline sales
// are received or a manager resolves one (dedupe key offline.process:<device_id>). For each
// received sale of the device, oldest sequence first:
//   1. verify (verify.ts): the signature with the key of the sale's lease, and the receipt UUID;
//   2. public.offline_worker_process -> app.offline_process: post it exactly as printed, or park it
//      as a conflict, and release its receipt for submission unless it is held.
// Concurrent runs can't double-post: the database takes each row with SKIP LOCKED and only while
// it is still 'received'. Ids, numbers and codes are logged; never the content or the signature.

import type { SupabaseClient } from '@supabase/supabase-js';
import { EtaEnvironment } from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { EtaHostMap } from '../eta/config';
import type { JobHandler } from '../jobs/types';
import { captureProblem } from '../utils/monitoring';
import { checkReceiptUuid, offlineQr, verifyOfflineSignature } from './verify';

const ReceivedRow = z.object({
  id: z.string().uuid(),
  organization_id: z.string().uuid(),
  device_id: z.string().uuid(),
  seq: z.number().int(),
  number: z.string(),
  content: z.string(),
  signature: z.string(),
  eta_uuid: z.string().nullable(),
  public_key: z.string(),
  environment: EtaEnvironment.nullable(),
  receipt_json: z.string().nullable(),
});
/** A received sale with what is verified. Holds the content and signature: never log it. */
export type ReceivedRow = z.infer<typeof ReceivedRow>;

const ProcessResult = z.object({
  id: z.string().uuid(),
  skipped: z.boolean().optional(),
  status: z.string().optional(),
  code: z.string().nullable().optional(),
  released: z.boolean().optional(),
  alerts: z.array(z.string()).optional(),
});
export type ProcessResult = z.infer<typeof ProcessResult>;

export interface OfflineStore {
  /** The device's received sales, oldest sequence first. */
  loadReceived(deviceId: string, limit: number): Promise<ReceivedRow[]>;
  process(
    id: string,
    signatureOk: boolean,
    uuidOk: boolean,
    qr: string | null,
  ): Promise<ProcessResult>;
}

export function supabaseOfflineStore(db: SupabaseClient): OfflineStore {
  return {
    async loadReceived(deviceId, limit) {
      const { data, error } = await db.rpc('offline_worker_load', {
        p_device_id: deviceId,
        p_limit: limit,
      });
      if (error) throw new Error(`offline_worker_load failed (${error.code})`);
      return z.array(ReceivedRow).parse(data);
    },
    async process(id, signatureOk, uuidOk, qr) {
      const { data, error } = await db.rpc('offline_worker_process', {
        p_id: id,
        p_signature_ok: signatureOk,
        p_uuid_ok: uuidOk,
        p_qr: qr,
      });
      if (error) {
        const token = /^[A-Z][A-Z_]+/.exec(error.message)?.[0] ?? 'database error';
        throw new Error(`offline_worker_process failed: ${token} (${error.code})`);
      }
      return ProcessResult.parse(data);
    },
  };
}

export interface OfflineProcessDeps {
  store: OfflineStore;
  hosts: EtaHostMap;
  /** Rows read per pass. */
  batchSize?: number;
}

/** What the worker decides for one row before the database posts it. */
export function verifyRow(
  row: ReceivedRow,
  hosts: EtaHostMap,
): { signatureOk: boolean; uuidOk: boolean; qr: string | null } {
  const signatureOk = verifyOfflineSignature(row.content, row.signature, row.public_key);
  if (row.receipt_json === null) return { signatureOk, uuidOk: true, qr: null };
  const facts = checkReceiptUuid(row.receipt_json, row.eta_uuid);
  const qr = facts && row.environment ? offlineQr(hosts[row.environment].portalUrl, facts) : null;
  return { signatureOk, uuidOk: facts !== null, qr };
}

const Payload = z.object({ device_id: z.string().uuid() });

export function offlineJobHandlers(
  deps: OfflineProcessDeps,
): Record<'offline.process', JobHandler> {
  const batchSize = deps.batchSize ?? 50;
  return {
    'offline.process': async (job, log) => {
      const { device_id: deviceId } = Payload.parse(job.payload);
      // A pass that posts nothing new ends the job (rows another run holds are skipped).
      for (;;) {
        const rows = await deps.store.loadReceived(deviceId, batchSize);
        let done = 0;
        for (const row of rows) {
          const checks = verifyRow(row, deps.hosts);
          const result = await deps.store.process(
            row.id,
            checks.signatureOk,
            checks.uuidOk,
            checks.qr,
          );
          if (result.skipped) continue;
          done += 1;
          const tags = {
            problem: 'offline',
            orgId: row.organization_id,
            deviceId,
            offlineSaleId: row.id,
            number: row.number,
            code: result.code ?? null,
          };
          for (const alert of result.alerts ?? []) {
            log.error({ ...tags, alert }, 'offline sale problem');
            captureProblem(`offline: ${alert}`, { ...tags, alert });
          }
          log.info(
            {
              offlineSaleId: row.id,
              number: row.number,
              status: result.status,
              code: result.code,
              released: result.released,
            },
            'offline sale processed',
          );
        }
        if (done === 0 || rows.length < batchSize) return;
      }
    },
  };
}
