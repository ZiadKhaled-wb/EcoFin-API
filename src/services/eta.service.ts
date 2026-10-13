// T02 ETA e-receipts (D67). The shop side: the ETA connection, each POS's registration, a manual
// retry, and the `eta` part of a sale. Settings, devices and the retry go through the caller's
// own client and the T02 database functions, which check the permission, validate and audit.
// Secrets go in and never come out: an answer says only whether one is stored.
import {
  Device,
  DeviceList,
  EtaSettings,
  FiscalRetryResult,
  type DeviceEtaBody,
  type EtaSettingsBody,
  type EtaTestResult,
  type Sale,
} from '@ziadkhaled-wb/contracts';
import { EtaError } from '../eta/client';
import { prepareDevice } from '../eta/prepare';
import { etaRuntime } from '../eta/runtime';
import type { SaleReceipt } from '../eta/store';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, NotFound, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function getSettings(ctx: RequestContext): Promise<EtaSettings> {
  const { data, error } = await ctx.db.rpc('get_eta_settings');
  if (error) fail(error);
  return EtaSettings.parse(data);
}

/** Replaces the settings. Without `client_secret` the stored secret is kept. */
export async function setSettings(
  ctx: RequestContext,
  body: EtaSettingsBody,
): Promise<EtaSettings> {
  const { data, error } = await ctx.db.rpc('set_eta_settings', {
    p_environment: body.environment,
    p_client_id: body.client_id ?? '',
    p_activity_code: body.activity_code ?? '',
    p_enabled: body.is_enabled,
    ...(body.client_secret ? { p_client_secret: body.client_secret } : {}),
  });
  if (error) fail(error);
  return EtaSettings.parse(data);
}

export async function listDevices(ctx: RequestContext): Promise<DeviceList> {
  const { data, error } = await ctx.db.rpc('list_devices');
  if (error) fail(error);
  return DeviceList.parse(data);
}

/** A POS's ETA registration. Without `preshared_key` the stored key is kept. */
export async function setDeviceEta(
  ctx: RequestContext,
  id: string,
  body: DeviceEtaBody,
): Promise<Device> {
  const { data, error } = await ctx.db.rpc('set_device_eta', {
    p_device_id: id,
    p_serial: body.eta_serial ?? '',
    p_os_version: body.eta_os_version ?? '',
    p_model_framework: body.eta_model_framework ?? '',
    p_status: body.eta_status,
    ...(body.preshared_key ? { p_preshared_key: body.preshared_key } : {}),
  });
  if (error) fail(error);
  return Device.parse(data);
}

export async function retrySubmission(ctx: RequestContext, id: string): Promise<FiscalRetryResult> {
  const { data, error } = await ctx.db.rpc('retry_fiscal_submission', { p_id: id });
  if (error) fail(error);
  return FiscalRetryResult.parse(data);
}

/**
 * Logs one of the caller's POS devices in at the ETA with the stored credentials (a new token,
 * not the cached one). Answers ok, or the ETA's error code: never a secret or a token.
 */
export async function testConnection(
  ctx: RequestContext,
  deviceId: string,
): Promise<EtaTestResult> {
  // The caller's own list: a POS of another shop or of a branch they can't see is not found.
  const devices = await listDevices(ctx);
  if (!devices.some((device) => device.id === deviceId)) {
    throw NotFound('Device not found.', 'DEVICE_NOT_FOUND');
  }
  const { store, client } = etaRuntime();
  const row = await store.credentials(ctx.orgId, deviceId);
  if (!row) throw NotFound('Device not found.', 'DEVICE_NOT_FOUND');
  const {
    client_id,
    client_secret,
    pos_serial,
    pos_os_version,
    pos_model_framework,
    preshared_key,
  } = row;
  if (
    !client_id ||
    !client_secret ||
    !pos_serial ||
    !pos_os_version ||
    !pos_model_framework ||
    !preshared_key
  ) {
    return { ok: false, message: 'incomplete_settings' };
  }
  try {
    await client.token(
      {
        environment: row.environment,
        deviceId,
        credentials: {
          clientId: client_id,
          clientSecret: client_secret,
          posSerial: pos_serial,
          posOsVersion: pos_os_version,
          posModelFramework: pos_model_framework,
          presharedKey: preshared_key,
        },
      },
      { fresh: true },
    );
    return { ok: true, message: null };
  } catch (err) {
    if (!(err instanceof EtaError)) throw err;
    // The ETA's own code (`invalid_presharedkey`, ...) when it is one; never free text.
    const code =
      err.code !== undefined && /^[A-Za-z0-9_.-]{1,60}$/.test(err.code) ? err.code : null;
    return { ok: false, message: code ?? (err.kind === 'unknown' ? 'unreachable' : err.kind) };
  }
}

/** How long a sale waits for its receipt to be built before answering without the QR code. */
const PREPARE_BUDGET_MS = 2000;

/** The sale's receipt as it is now; null when it has none. Never fails the sale it belongs to. */
async function saleReceipt(ctx: RequestContext, saleId: string): Promise<SaleReceipt | null> {
  try {
    return await etaRuntime().store.saleStatus(ctx.orgId, saleId);
  } catch (err) {
    logger.error({ err, saleId }, 'the ETA status of a sale could not be read');
    return null;
  }
}

/** `GET /sales/:id`: the sale with its receipt (reprints). */
export async function withEta(ctx: RequestContext, sale: Sale): Promise<Sale> {
  return { ...sale, eta: (await saleReceipt(ctx, sale.id))?.eta ?? null };
}

/**
 * A sale that was just made: its receipt is built now, so the first print has the QR code. At
 * most 2 seconds: after that, or on any failure, the sale answers as it is and the eta.prepare
 * job builds the receipt. The sale itself is already committed and is never failed from here.
 */
export async function withFreshEta(ctx: RequestContext, sale: Sale): Promise<Sale> {
  const first = await saleReceipt(ctx, sale.id);
  if (first?.eta.status !== 'pending' || first.eta.uuid !== null) {
    return { ...sale, eta: first?.eta ?? null };
  }

  const { store, hosts } = etaRuntime();
  const work = prepareDevice(
    { store, hosts, logger },
    { deviceId: first.deviceId, branchId: first.branchId },
    { deadline: Date.now() + PREPARE_BUDGET_MS },
  ).catch((err: unknown) => {
    logger.warn({ err, saleId: sale.id }, 'the receipt was not built with the sale; the job will');
  });
  let timer: NodeJS.Timeout | undefined;
  const budget = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, PREPARE_BUDGET_MS);
  });
  await Promise.race([work, budget]);
  clearTimeout(timer);
  return { ...sale, eta: (await saleReceipt(ctx, sale.id))?.eta ?? first.eta };
}
