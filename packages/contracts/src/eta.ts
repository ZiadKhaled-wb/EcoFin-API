import { z } from 'zod';
import { IsoTimestamp, Uuid } from './common.js';

/**
 * T02 ETA e-receipts (D67). The shop's connection to the Egyptian Tax Authority, each POS
 * device's ETA registration, and what a sale shows of its receipt. Secrets are write-only: the
 * API answers only whether one is stored (`has_client_secret`, `has_preshared_key`).
 */

/** Values of `public.eta_environment`. `preprod` is the ETA's test system. */
export const EtaEnvironment = z.enum(['preprod', 'prod']);
export type EtaEnvironment = z.infer<typeof EtaEnvironment>;

/** Values of `public.device_status`: a POS's registration with the ETA. */
export const DeviceEtaStatus = z.enum(['unregistered', 'pending', 'active', 'revoked']);
export type DeviceEtaStatus = z.infer<typeof DeviceEtaStatus>;

/** Values of `public.fiscal_status`. */
export const FiscalStatus = z.enum([
  'pending',
  'submitted',
  'accepted',
  'rejected',
  'failed',
  'cancelled',
]);
export type FiscalStatus = z.infer<typeof FiscalStatus>;

/** Up to 10 letters or digits (the ETA's activity code). */
export const ETA_ACTIVITY_CODE_PATTERN = /^[0-9A-Za-z]{1,10}$/;

/** "" -> null, so a cleared input clears the value. */
const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .nullable()
    .transform((v) => (v === '' ? null : v));

// GET /api/eta/settings
export const EtaSettings = z.object({
  environment: EtaEnvironment,
  client_id: z.string().nullable(),
  has_client_secret: z.boolean(),
  activity_code: z.string().nullable(),
  is_enabled: z.boolean(),
  updated_at: IsoTimestamp.nullable(),
});
export type EtaSettings = z.infer<typeof EtaSettings>;

// PUT /api/eta/settings
export const EtaSettingsBody = z
  .object({
    environment: EtaEnvironment,
    client_id: optionalText(100),
    /** Write-only. Left out or null: the stored secret is kept. */
    client_secret: z.string().min(1).max(100).nullable().optional(),
    activity_code: optionalText(10).refine(
      (v) => v === null || ETA_ACTIVITY_CODE_PATTERN.test(v),
      'Must be up to 10 letters or digits',
    ),
    is_enabled: z.boolean(),
  })
  .strict();
export type EtaSettingsBody = z.infer<typeof EtaSettingsBody>;

// POST /api/eta/settings/test
export const EtaTestBody = z.object({ device_id: Uuid }).strict();
export type EtaTestBody = z.infer<typeof EtaTestBody>;

/** `message` is the ETA's own error code or a short reason; null when ok. Never a secret. */
export const EtaTestResult = z.object({ ok: z.boolean(), message: z.string().nullable() });
export type EtaTestResult = z.infer<typeof EtaTestResult>;

// GET /api/devices
export const Device = z.object({
  id: Uuid,
  name: z.string(),
  branch_id: Uuid,
  branch_name: z.string(),
  eta_serial: z.string().nullable(),
  eta_os_version: z.string().nullable(),
  eta_model_framework: z.string().nullable(),
  eta_status: DeviceEtaStatus,
  has_preshared_key: z.boolean(),
  is_active: z.boolean(),
  /** O03: this device holds a token (a computer was paired with it). Never the token. */
  paired: z.boolean(),
  paired_at: IsoTimestamp.nullable(),
  last_seen_at: IsoTimestamp.nullable(),
});
export type Device = z.infer<typeof Device>;
export const DeviceList = z.array(Device);
export type DeviceList = z.infer<typeof DeviceList>;

export const DeviceIdParams = z.object({ id: Uuid }).strict();

// PUT /api/devices/:id/eta
export const DeviceEtaBody = z
  .object({
    eta_serial: optionalText(100),
    eta_os_version: optionalText(50),
    eta_model_framework: optionalText(10),
    /** Write-only. Left out or null: the stored key is kept. */
    preshared_key: z.string().min(1).max(200).nullable().optional(),
    eta_status: DeviceEtaStatus,
  })
  .strict();
export type DeviceEtaBody = z.infer<typeof DeviceEtaBody>;

// POST /api/eta/submissions/:id/retry
export const FiscalSubmissionIdParams = z.object({ id: Uuid }).strict();
export const FiscalRetryResult = z.object({ id: Uuid, status: FiscalStatus });
export type FiscalRetryResult = z.infer<typeof FiscalRetryResult>;

/**
 * A sale's ETA receipt, on the sale answer and on `GET /sales/:id` (reprints).
 * `uuid` and `qr_payload` are set once the receipt is built; `qr_payload` is the text to print
 * as a QR code. `last_error_code` is the start of the last error (`BLOCKED:ITEM_CODE`,
 * `ETA_INVALID`, ...), null without one.
 */
export const SaleEta = z.object({
  status: FiscalStatus,
  uuid: z.string().nullable(),
  qr_payload: z.string().nullable(),
  last_error_code: z.string().nullable(),
});
export type SaleEta = z.infer<typeof SaleEta>;
