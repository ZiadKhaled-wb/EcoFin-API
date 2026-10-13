import type { Sale } from '@ziadkhaled-wb/contracts';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EtaError } from '../eta/client';
import { prepareDevice } from '../eta/prepare';
import type { CredentialsRow, SaleReceipt } from '../eta/store';
import type { RequestContext } from '../middleware/requestContext';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import {
  getSettings,
  retrySubmission,
  setDeviceEta,
  setSettings,
  testConnection,
  withEta,
  withFreshEta,
} from './eta.service';

const ORG = 'a0900000-0000-4000-8000-000000000001';
const DEVICE = 'a0900000-0000-4000-8000-000000000002';
const BRANCH = 'a0900000-0000-4000-8000-000000000003';
const SALE = 'a0900000-0000-4000-8000-000000000004';
const SECRET = 'client-secret-value';
const KEY = 'preshared-key-value';

const runtime = vi.hoisted(() => ({
  saleStatus: vi.fn(),
  credentials: vi.fn(),
  token: vi.fn(),
}));
vi.mock('../eta/runtime', () => ({
  etaRuntime: () => ({
    store: { saleStatus: runtime.saleStatus, credentials: runtime.credentials },
    client: { token: runtime.token },
    hosts: {},
  }),
}));
vi.mock('../eta/prepare', () => ({ prepareDevice: vi.fn() }));

function setup() {
  const db = createSupabaseMock();
  const ctx = { orgId: ORG, db: db as unknown as DbClient } as RequestContext;
  return { db, ctx };
}

const settings = {
  environment: 'preprod',
  client_id: 'client-1',
  has_client_secret: true,
  activity_code: '4620',
  is_enabled: true,
  updated_at: '2026-10-12T09:00:00+00:00',
};
const device = {
  id: DEVICE,
  name: 'Till 1',
  branch_id: BRANCH,
  branch_name: 'Main',
  eta_serial: 'POS-001',
  eta_os_version: 'os',
  eta_model_framework: '1',
  eta_status: 'active',
  has_preshared_key: true,
  is_active: true,
  paired: false,
  paired_at: null,
  last_seen_at: null,
};
const credentials: CredentialsRow = {
  environment: 'preprod',
  client_id: 'client-1',
  client_secret: SECRET,
  pos_serial: 'POS-001',
  pos_os_version: 'os',
  pos_model_framework: '1',
  preshared_key: KEY,
  device_status: 'active',
  device_active: true,
};
const sale = { id: SALE, branch_id: BRANCH, number: 'MAIN-SL-26-000001' } as Sale;
const receipt = (over: Partial<SaleReceipt['eta']> = {}): SaleReceipt => ({
  eta: { status: 'pending', uuid: null, qr_payload: null, last_error_code: null, ...over },
  deviceId: DEVICE,
  branchId: BRANCH,
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(prepareDevice).mockResolvedValue({ prepared: 1, blocked: 0, finished: true });
});

describe('T02 ETA settings and devices', () => {
  it('reads the settings: whether a secret is stored, never the secret', async () => {
    const { db, ctx } = setup();
    db.queue({ data: settings, error: null });
    expect(await getSettings(ctx)).toEqual(settings);
    expect(db.rpc).toHaveBeenLastCalledWith('get_eta_settings');
  });

  it('sends the secret only when one was typed', async () => {
    const { db, ctx } = setup();
    const body = {
      environment: 'preprod' as const,
      client_id: 'client-1',
      activity_code: '4620',
      is_enabled: true,
    };
    db.queue({ data: settings, error: null });
    await setSettings(ctx, body);
    expect(db.rpc).toHaveBeenLastCalledWith('set_eta_settings', {
      p_environment: 'preprod',
      p_client_id: 'client-1',
      p_activity_code: '4620',
      p_enabled: true,
    });
    db.queue({ data: settings, error: null });
    const answer = await setSettings(ctx, { ...body, client_secret: SECRET });
    expect(db.rpc).toHaveBeenLastCalledWith(
      'set_eta_settings',
      expect.objectContaining({ p_client_secret: SECRET }),
    );
    expect(JSON.stringify(answer)).not.toContain(SECRET);
  });

  it('maps the database refusals to contract codes', async () => {
    const { db, ctx } = setup();
    const body = {
      environment: 'prod' as const,
      client_id: null,
      activity_code: null,
      is_enabled: false,
    };
    for (const [message, status, code] of [
      ['ETA_ENV_BUSY: receipts are still on their way to preprod', 409, 'ETA_ENV_BUSY'],
      ['MODULE_NOT_IN_PLAN: eta', 403, 'MODULE_NOT_IN_PLAN'],
      ['PERMISSION_DENIED: org.settings_manage', 403, 'PERMISSION_DENIED'],
      ['VALIDATION_FAILED: ETA settings', 400, 'VALIDATION_FAILED'],
    ] as const) {
      db.queue({ data: null, error: { code: 'P0001', message } });
      await expect(setSettings(ctx, body)).rejects.toMatchObject({ statusCode: status, code });
    }
  });

  it('sets the registration of a POS; the key only when one was typed', async () => {
    const { db, ctx } = setup();
    const body = {
      eta_serial: 'POS-001',
      eta_os_version: 'os',
      eta_model_framework: '1',
      eta_status: 'active' as const,
    };
    db.queue({ data: device, error: null });
    expect(await setDeviceEta(ctx, DEVICE, body)).toEqual(device);
    expect(db.rpc).toHaveBeenLastCalledWith('set_device_eta', {
      p_device_id: DEVICE,
      p_serial: 'POS-001',
      p_os_version: 'os',
      p_model_framework: '1',
      p_status: 'active',
    });
    db.queue({ data: device, error: null });
    await setDeviceEta(ctx, DEVICE, { ...body, preshared_key: KEY });
    expect(db.rpc).toHaveBeenLastCalledWith(
      'set_device_eta',
      expect.objectContaining({ p_preshared_key: KEY }),
    );
    for (const [message, status, code] of [
      ['DEVICE_NOT_FOUND', 404, 'DEVICE_NOT_FOUND'],
      ['DEVICE_SERIAL_TAKEN', 409, 'DEVICE_SERIAL_TAKEN'],
    ] as const) {
      db.queue({ data: null, error: { code: 'P0001', message } });
      await expect(setDeviceEta(ctx, DEVICE, body)).rejects.toMatchObject({
        statusCode: status,
        code,
      });
    }
  });

  it('retries a receipt; another shop, or one that is not failed, is refused', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { id: SALE, status: 'pending' }, error: null });
    expect(await retrySubmission(ctx, SALE)).toEqual({ id: SALE, status: 'pending' });
    expect(db.rpc).toHaveBeenLastCalledWith('retry_fiscal_submission', { p_id: SALE });
    for (const [message, status, code] of [
      ['FISCAL_NOT_FOUND', 404, 'FISCAL_NOT_FOUND'],
      ['FISCAL_NOT_RETRYABLE: the receipt is accepted', 409, 'FISCAL_NOT_RETRYABLE'],
      ['ETA_ENV_MISMATCH: the receipt belongs to preprod', 409, 'ETA_ENV_MISMATCH'],
    ] as const) {
      db.queue({ data: null, error: { code: 'P0001', message } });
      await expect(retrySubmission(ctx, SALE)).rejects.toMatchObject({ statusCode: status, code });
    }
  });
});

describe('T02 connection test', () => {
  it('logs the POS in with a new token and answers ok', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [device], error: null });
    runtime.credentials.mockResolvedValue(credentials);
    runtime.token.mockResolvedValue('the-token');
    const answer = await testConnection(ctx, DEVICE);
    expect(answer).toEqual({ ok: true, message: null });
    expect(runtime.credentials).toHaveBeenCalledWith(ORG, DEVICE);
    expect(runtime.token).toHaveBeenCalledWith(
      expect.objectContaining({ environment: 'preprod', deviceId: DEVICE }),
      { fresh: true },
    );
  });

  it('answers the error code of the ETA only: never a secret, a key or a token', async () => {
    const { db, ctx } = setup();
    runtime.credentials.mockResolvedValue(credentials);
    for (const [error, message] of [
      [
        new EtaError('auth', 'invalid_presharedkey', { code: 'invalid_presharedkey' }),
        'invalid_presharedkey',
      ],
      [new EtaError('unknown', `could not reach with ${SECRET}`), 'unreachable'],
      [new EtaError('auth', `refused ${KEY}`), 'auth'],
    ] as const) {
      db.queue({ data: [device], error: null });
      runtime.token.mockRejectedValueOnce(error);
      const answer = await testConnection(ctx, DEVICE);
      expect(answer).toEqual({ ok: false, message });
      expect(JSON.stringify(answer)).not.toContain(SECRET);
      expect(JSON.stringify(answer)).not.toContain(KEY);
    }
  });

  it('says when the settings or the registration are incomplete, without calling the ETA', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [device], error: null });
    runtime.credentials.mockResolvedValue({ ...credentials, preshared_key: null });
    expect(await testConnection(ctx, DEVICE)).toEqual({
      ok: false,
      message: 'incomplete_settings',
    });
    expect(runtime.token).not.toHaveBeenCalled();
  });

  it('a POS that is not in the list of the caller is not found, and no credentials are read', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [device], error: null });
    await expect(testConnection(ctx, SALE)).rejects.toMatchObject({
      statusCode: 404,
      code: 'DEVICE_NOT_FOUND',
    });
    expect(runtime.credentials).not.toHaveBeenCalled();
  });
});

describe('T02 the receipt of a sale', () => {
  it('a read sale carries the receipt as it is now; none is null', async () => {
    const { ctx } = setup();
    runtime.saleStatus.mockResolvedValueOnce(receipt({ status: 'accepted', uuid: 'a'.repeat(64) }));
    expect((await withEta(ctx, sale)).eta).toMatchObject({ status: 'accepted' });
    expect(runtime.saleStatus).toHaveBeenCalledWith(ORG, SALE);
    runtime.saleStatus.mockResolvedValueOnce(null);
    expect((await withEta(ctx, sale)).eta).toBeNull();
    // The POS and branch the receipt is prepared for stay on the server.
    runtime.saleStatus.mockResolvedValueOnce(receipt());
    expect(Object.keys((await withEta(ctx, sale)).eta ?? {})).toEqual([
      'status',
      'uuid',
      'qr_payload',
      'last_error_code',
    ]);
  });

  it('a new sale builds its receipt at once and answers the QR text', async () => {
    const { ctx } = setup();
    const ready = receipt({ uuid: 'b'.repeat(64), qr_payload: 'https://portal/qr' });
    runtime.saleStatus.mockResolvedValueOnce(receipt()).mockResolvedValueOnce(ready);
    const answered = await withFreshEta(ctx, sale);
    expect(prepareDevice).toHaveBeenCalledTimes(1);
    const [, target, options] = vi.mocked(prepareDevice).mock.calls[0] ?? [];
    expect(target).toEqual({ deviceId: DEVICE, branchId: BRANCH });
    expect(typeof options?.deadline).toBe('number');
    expect(answered.eta).toEqual(ready.eta);
    expect(answered.number).toBe(sale.number);
  });

  it('does nothing for a sale without a receipt, or one that is already built or blocked', async () => {
    const { ctx } = setup();
    runtime.saleStatus.mockResolvedValueOnce(null);
    expect((await withFreshEta(ctx, sale)).eta).toBeNull();
    runtime.saleStatus.mockResolvedValueOnce(receipt({ uuid: 'c'.repeat(64) }));
    expect((await withFreshEta(ctx, sale)).eta?.uuid).toBe('c'.repeat(64));
    runtime.saleStatus.mockResolvedValueOnce(
      receipt({ status: 'failed', last_error_code: 'BLOCKED:NO_DEVICE' }),
    );
    expect((await withFreshEta(ctx, sale)).eta?.last_error_code).toBe('BLOCKED:NO_DEVICE');
    expect(prepareDevice).not.toHaveBeenCalled();
  });

  it('never fails the sale: a build that throws answers the sale as it is', async () => {
    const { ctx } = setup();
    runtime.saleStatus.mockResolvedValue(receipt());
    vi.mocked(prepareDevice).mockRejectedValue(new Error('database is down'));
    const answered = await withFreshEta(ctx, sale);
    expect(answered.eta).toEqual(receipt().eta);
    runtime.saleStatus.mockReset();
    runtime.saleStatus.mockRejectedValue(new Error('database is down'));
    expect((await withFreshEta(ctx, sale)).eta).toBeNull();
    expect((await withEta(ctx, sale)).eta).toBeNull();
  });

  it('waits 2 seconds at most for the receipt, then answers without the QR code', async () => {
    vi.useFakeTimers();
    try {
      const { ctx } = setup();
      runtime.saleStatus.mockResolvedValue(receipt());
      vi.mocked(prepareDevice).mockReturnValue(new Promise(() => undefined)); // never finishes
      let answered: Sale | undefined;
      const pending = withFreshEta(ctx, sale).then((s) => {
        answered = s;
      });
      await vi.advanceTimersByTimeAsync(1999);
      expect(answered).toBeUndefined();
      await vi.advanceTimersByTimeAsync(1);
      await pending;
      expect(answered?.eta).toEqual(receipt().eta);
    } finally {
      vi.useRealTimers();
    }
  });
});
