// O03 device service: what goes to the database is a hash, what comes back once is the secret.
import { createHash } from 'node:crypto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { errorCodeHttpStatus, isPairingCode, type ErrorCode } from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import {
  createDevice,
  createPairingCode,
  pairDevice,
  setDeviceActive,
  unpairDevice,
  updateDevice,
} from './devices.service';

const ORG = 'a0300000-0000-4000-8000-000000000001';
const DEVICE = 'a0300000-0000-4000-8000-000000000002';
const BRANCH = 'a0300000-0000-4000-8000-000000000003';
const sha256 = (value: string) => createHash('sha256').update(value, 'utf8').digest('hex');

function setup() {
  const db = createSupabaseMock();
  const ctx = { orgId: ORG, db: db as unknown as DbClient } as RequestContext;
  return { db, ctx };
}
const row = {
  id: DEVICE,
  name: 'POS-1',
  branch_id: BRANCH,
  branch_name: 'Main',
  eta_serial: null,
  eta_os_version: null,
  eta_model_framework: null,
  eta_status: 'unregistered',
  has_preshared_key: false,
  is_active: true,
  paired: false,
  paired_at: null,
  last_seen_at: null,
};
const paired = { device_id: DEVICE, name: 'POS-1', branch_id: BRANCH, branch_name: 'Main' };

beforeEach(() => {
  vi.useRealTimers();
});

describe('O03 managing devices', () => {
  it('creates a device and answers its id', async () => {
    const { db, ctx } = setup();
    db.queue({ data: DEVICE, error: null });
    expect(await createDevice(ctx, { branch_id: BRANCH, name: 'POS-1' })).toEqual({ id: DEVICE });
    expect(db.rpc).toHaveBeenCalledWith('create_device', { p_branch_id: BRANCH, p_name: 'POS-1' });
  });

  it('an update sends only the part that changes', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row, error: null }, { data: row, error: null });
    await updateDevice(ctx, DEVICE, { name: 'POS-2' });
    expect(db.rpc).toHaveBeenLastCalledWith('update_device', {
      p_device_id: DEVICE,
      p_name: 'POS-2',
    });
    await updateDevice(ctx, DEVICE, { branch_id: BRANCH });
    expect(db.rpc).toHaveBeenLastCalledWith('update_device', {
      p_device_id: DEVICE,
      p_branch_id: BRANCH,
    });
  });

  it('turning a device off passes the reason; the answer is id and is_active only', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { id: DEVICE, is_active: false, token_hash: 'h' }, error: null });
    expect(await setDeviceActive(ctx, DEVICE, { active: false, reason: 'stolen' })).toEqual({
      id: DEVICE,
      is_active: false,
    });
    expect(db.rpc).toHaveBeenCalledWith('set_device_active', {
      p_device_id: DEVICE,
      p_active: false,
      p_reason: 'stolen',
    });
  });

  it('unpairs a device', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { id: DEVICE, paired: false }, error: null });
    expect(await unpairDevice(ctx, DEVICE)).toEqual({ id: DEVICE, paired: false });
    expect(db.rpc).toHaveBeenCalledWith('unpair_device', { p_device_id: DEVICE });
  });
});

describe('O03 pairing', () => {
  it('a pairing code is answered once; the database gets its hash and a 15-minute expiry', async () => {
    vi.useFakeTimers({ now: new Date('2026-10-13T09:00:00.000Z') });
    const { db, ctx } = setup();
    db.queue({ data: { id: DEVICE, expires_at: '2026-10-13T09:15:00+00:00' }, error: null });
    const made = await createPairingCode(ctx, DEVICE);
    expect(isPairingCode(made.code)).toBe(true);
    expect(made.expires_at).toBe('2026-10-13T09:15:00.000Z');
    expect(db.rpc).toHaveBeenCalledTimes(1);
    expect(db.rpc).toHaveBeenCalledWith('create_device_pairing_code', {
      p_device_id: DEVICE,
      p_code_hash: sha256(made.code),
      p_expires_at: '2026-10-13T09:15:00.000Z',
    });
    expect(JSON.stringify(db.rpc.mock.calls)).not.toContain(made.code);
  });

  it('pairing sends the hash of the typed code and of a new token; the token is answered once', async () => {
    const { db, ctx } = setup();
    db.queue({ data: paired, error: null });
    const answer = await pairDevice(ctx, ' abcd-efgh ');
    expect(Buffer.from(answer.device_token, 'base64url')).toHaveLength(32);
    expect(answer.device).toEqual({
      id: DEVICE,
      name: 'POS-1',
      branch_id: BRANCH,
      branch_name: 'Main',
    });
    expect(db.rpc).toHaveBeenCalledTimes(1);
    expect(db.rpc).toHaveBeenCalledWith('pair_device', {
      p_code_hash: sha256('ABCDEFGH'),
      p_token_hash: sha256(answer.device_token),
    });
    const sent = JSON.stringify(db.rpc.mock.calls);
    expect(sent).not.toContain(answer.device_token);
    expect(sent).not.toContain('ABCDEFGH');
  });

  it('NULL from the database (a failed or rate-limited attempt) is PAIRING_CODE_INVALID, and no token is answered', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: null });
    await expect(pairDevice(ctx, 'ABCDEFGH')).rejects.toMatchObject({
      statusCode: 400,
      code: 'PAIRING_CODE_INVALID',
    });
    expect(db.rpc).toHaveBeenCalledTimes(1);
  });

  it('two pairings never share a token', async () => {
    const { db, ctx } = setup();
    db.queue({ data: paired, error: null }, { data: paired, error: null });
    const a = await pairDevice(ctx, 'ABCDEFGH');
    const b = await pairDevice(ctx, 'ABCDEFGH');
    expect(a.device_token).not.toBe(b.device_token);
  });

  it.each(['ABCDEFG', 'ABCDEFGHJ', 'ABCDEFG0', 'ABCDEFGL', '????????'])(
    'a code of the wrong shape (%s) is PAIRING_CODE_INVALID without asking the database',
    async (typed) => {
      const { db, ctx } = setup();
      await expect(pairDevice(ctx, typed)).rejects.toMatchObject({
        statusCode: 400,
        code: 'PAIRING_CODE_INVALID',
      });
      expect(db.rpc).not.toHaveBeenCalled();
    },
  );
});

describe('O03 error mapping', () => {
  const cases: [ErrorCode, number][] = [
    ['DEVICE_REQUIRED', 409],
    ['DEVICE_HAS_OPEN_SHIFT', 409],
    ['DEVICE_NAME_TAKEN', 409],
    ['DEVICE_BRANCH_MISMATCH', 409],
    ['DEVICE_MISMATCH', 409],
    ['DEVICE_REVOKED', 403],
    ['DEVICE_NOT_FOUND', 404],
    ['PAIRING_CODE_INVALID', 400],
  ];

  it.each(cases)('%s from the database -> %i with that code', async (code, status) => {
    expect(errorCodeHttpStatus[code]).toBe(status);
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: `${code}: detail the client never sees` } });
    await expect(updateDevice(ctx, DEVICE, { name: 'POS-2' })).rejects.toMatchObject({
      statusCode: status,
      code,
    });
  });

  it('the plan limit keeps its details; an unknown database error is a plain server error', async () => {
    const { db, ctx } = setup();
    db.queue(
      {
        data: null,
        error: {
          message: 'PLAN_LIMIT_REACHED',
          details: JSON.stringify({ limit: 'max_devices', max: 2, current: 2 }),
        },
      },
      { data: null, error: { message: 'duplicate key value violates unique constraint' } },
    );
    await expect(createDevice(ctx, { branch_id: BRANCH, name: 'POS-3' })).rejects.toMatchObject({
      statusCode: 409,
      code: 'PLAN_LIMIT_REACHED',
    });
    await expect(createDevice(ctx, { branch_id: BRANCH, name: 'POS-3' })).rejects.toMatchObject({
      statusCode: 500,
      code: 'INTERNAL',
      message: 'Request failed.',
    });
  });
});
