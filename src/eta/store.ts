// server/src/eta/store.ts
//
// T02 (D67). The receipts' database side: the service-role functions of migration
// 20261012120000_t02_eta_receipts.sql, called through PostgREST like F13's job store. Rows are
// checked with zod, so a database change that breaks a shape fails loudly instead of building a
// receipt from wrong data. An error names the function only, never its arguments (they carry
// receipts and secrets).

import { EtaEnvironment, FiscalStatus, SaleEta } from '@ziadkhaled-wb/contracts';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';

const nullableText = z.string().nullable();

const PendingRow = z.object({
  fiscal_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  environment: EtaEnvironment,
  sale: z.object({
    id: z.string().uuid(),
    number: z.string(),
    issued_at: z.string(),
    prices_include_vat: z.boolean(),
    total: z.string(),
  }),
  lines: z.array(
    z.object({
      line_no: z.number().int(),
      quantity: z.number().int(),
      unit_price: z.string(),
      discount_amount: z.string(),
      tax_rate: z.string(),
      tax_amount: z.string(),
      line_total: z.string(),
      sku: z.string(),
      name: z.string(),
      eta_item_code: nullableText,
      eta_item_type: nullableText,
      eta_tax_type: z.string(),
      eta_subtype: z.string(),
    }),
  ),
  payments: z.array(z.object({ method: z.string(), amount: z.string() })),
  customer: z
    .object({
      name: z.string(),
      national_id: nullableText,
      is_business: z.boolean(),
      tax_registration_no: nullableText,
    })
    .nullable(),
  seller: z.object({
    rin: nullableText,
    name: nullableText,
    activity_code: nullableText,
    branch_code: nullableText,
    governorate: nullableText,
    city: nullableText,
    street: nullableText,
    building_number: nullableText,
  }),
  device: z
    .object({
      id: z.string().uuid(),
      serial: nullableText,
      status: z.string(),
      is_active: z.boolean(),
    })
    .nullable(),
});
/** A pending sale with everything its receipt is built from. Holds a national ID: never log it. */
export type PendingRow = z.infer<typeof PendingRow>;

const Pending = z.object({ last_uuid: nullableText, rows: z.array(PendingRow) });

const CredentialsRow = z.object({
  environment: EtaEnvironment,
  client_id: nullableText,
  client_secret: nullableText,
  pos_serial: nullableText,
  pos_os_version: nullableText,
  pos_model_framework: nullableText,
  preshared_key: nullableText,
  device_status: z.string(),
  device_active: z.boolean(),
});
/** Secrets from Vault. Never log it. */
export type CredentialsRow = z.infer<typeof CredentialsRow>;

const SubmitRow = z.object({
  fiscal_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  environment: EtaEnvironment,
  internal_id: z.string(),
  uuid: z.string(),
  attempts: z.number().int(),
  receipt_json: z.string().min(2),
  /** A send was started before: the ETA may already have it. */
  was_sent: z.boolean(),
});
export type SubmitRow = z.infer<typeof SubmitRow>;

const SubmittedRow = z.object({
  fiscal_id: z.string().uuid(),
  uuid: z.string(),
  internal_id: z.string(),
});
export type SubmittedRow = z.infer<typeof SubmittedRow>;

const DeadlineRow = z.object({
  fiscal_id: z.string().uuid(),
  organization_id: z.string().uuid(),
  internal_id: z.string(),
  issued_at: z.string(),
});
export type DeadlineRow = z.infer<typeof DeadlineRow>;

const SaleStatusRow = SaleEta.extend({
  device_id: z.string().uuid().nullable(),
  branch_id: z.string().uuid(),
});

/** A sale's receipt as the client sees it, and the POS (or branch) it is prepared for. */
export interface SaleReceipt {
  eta: SaleEta;
  deviceId: string | null;
  branchId: string;
}

/** What a status change may carry (see public.eta_mark). */
export interface MarkFields {
  last_error?: string;
  retry_in_seconds?: number;
  poll_in_seconds?: number;
  eta_long_id?: string | null;
  eta_submission_uuid?: string | null;
}

export type EtaJobType = 'eta.prepare' | 'eta.submit' | 'eta.poll';

export interface EtaStore {
  /** Pending, unbuilt receipts of a POS (or, without one, of a branch's POS-less sales), oldest first. */
  loadPending(
    deviceId: string | null,
    branchId: string | null,
    limit: number,
  ): Promise<{ lastUuid: string; rows: PendingRow[] }>;
  /** null when the POS is not the shop's. */
  credentials(orgId: string, deviceId: string): Promise<CredentialsRow | null>;
  /** 'already': another worker built it. 'moved': the POS chain moved; read it again. */
  storePrepared(
    fiscalId: string,
    uuid: string,
    previousUuid: string,
    receiptJson: string,
    qr: string,
  ): Promise<'stored' | 'already' | 'moved'>;
  /** true when this call blocked the receipt. */
  block(fiscalId: string, code: string, message: string): Promise<boolean>;
  claimForSubmit(deviceId: string, limit: number, leaseSeconds: number): Promise<SubmitRow[]>;
  mark(fiscalId: string, status: FiscalStatus, fields?: MarkFields): Promise<FiscalStatus>;
  loadSubmitted(orgId: string, submissionUuid: string): Promise<SubmittedRow[]>;
  /** Receipts still pending `hours` after their sale; each is returned once, ever. */
  claimDeadlineAlerts(deviceId: string, hours: number, now: Date): Promise<DeadlineRow[]>;
  enqueue(
    orgId: string,
    type: EtaJobType,
    key: string,
    payload: Record<string, unknown>,
    delaySeconds: number,
  ): Promise<void>;
  /** null when the sale has no receipt (ETA off, or a B2B sale). */
  saleStatus(orgId: string, saleId: string): Promise<SaleReceipt | null>;
}

interface DbError {
  message: string;
  /** SQLSTATE. */
  code: string;
}

/** `eta_mark failed: FISCAL_BAD_TRANSITION (P0001)`: the leading code and the SQLSTATE only. */
function failure(fn: string, error: DbError): Error {
  const token = /^[A-Z][A-Z_]+/.exec(error.message)?.[0] ?? 'database error';
  return new Error(`${fn} failed: ${token} (${error.code})`);
}

export function supabaseEtaStore(db: SupabaseClient): EtaStore {
  /** The function's result, or its error (only the message's leading code is ever read). */
  async function rpc(
    fn: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: DbError | null }> {
    const { data, error } = await db.rpc(fn, args);
    return {
      data: data as unknown,
      error: error ? { message: error.message, code: error.code } : null,
    };
  }

  async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const { data, error } = await rpc(fn, args);
    if (error) throw failure(fn, error);
    return data;
  }

  return {
    async loadPending(deviceId, branchId, limit) {
      const data = await call('eta_load_pending_for_device', {
        p_device_id: deviceId,
        p_branch_id: branchId,
        p_limit: limit,
      });
      const parsed = Pending.parse(data);
      return { lastUuid: parsed.last_uuid ?? '', rows: parsed.rows };
    },

    async credentials(orgId, deviceId) {
      const data = await call('eta_credentials', { p_org: orgId, p_device: deviceId });
      return data === null ? null : CredentialsRow.parse(data);
    },

    async storePrepared(fiscalId, uuid, previousUuid, receiptJson, qr) {
      const { error } = await rpc('eta_store_prepared', {
        p_fiscal_id: fiscalId,
        p_uuid: uuid,
        p_previous_uuid: previousUuid,
        p_payload: { receipt_json: receiptJson },
        p_qr: qr,
      });
      if (!error) return 'stored';
      if (error.message.startsWith('CHAIN_MOVED')) return 'moved';
      if (error.message.startsWith('ALREADY_PREPARED')) return 'already';
      throw failure('eta_store_prepared', error);
    },

    async block(fiscalId, code, message) {
      const data = await call('eta_block', {
        p_fiscal_id: fiscalId,
        p_code: code,
        p_message: message,
      });
      return z.boolean().parse(data);
    },

    async claimForSubmit(deviceId, limit, leaseSeconds) {
      const data = await call('eta_claim_for_submit', {
        p_device_id: deviceId,
        p_limit: limit,
        p_lease_seconds: leaseSeconds,
      });
      return z.array(SubmitRow).parse(data);
    },

    async mark(fiscalId, status, fields = {}) {
      const data = await call('eta_mark', {
        p_fiscal_id: fiscalId,
        p_status: status,
        p_fields: fields,
      });
      return FiscalStatus.parse(data);
    },

    async loadSubmitted(orgId, submissionUuid) {
      const data = await call('eta_load_submitted', {
        p_org: orgId,
        p_submission_uuid: submissionUuid,
      });
      return z.array(SubmittedRow).parse(data);
    },

    async claimDeadlineAlerts(deviceId, hours, now) {
      const data = await call('eta_claim_deadline_alerts', {
        p_device_id: deviceId,
        p_hours: hours,
        p_now: now.toISOString(),
      });
      return z.array(DeadlineRow).parse(data);
    },

    async enqueue(orgId, type, key, payload, delaySeconds) {
      await call('eta_enqueue', {
        p_org: orgId,
        p_job_type: type,
        p_key: key,
        p_payload: payload,
        p_delay_seconds: Math.max(0, Math.round(delaySeconds)),
      });
    },

    async saleStatus(orgId, saleId) {
      const data = await call('eta_sale_status', { p_org: orgId, p_sale_id: saleId });
      if (data === null) return null;
      const { device_id, branch_id, ...eta } = SaleStatusRow.parse(data);
      return { eta, deviceId: device_id, branchId: branch_id };
    },
  };
}
