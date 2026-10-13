// O03 deviceContext: the device of a request comes from its device token and from nowhere else.
// dbFor is mocked: resolve_device answers what each test needs.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction, RequestHandler } from 'express';

const db = vi.hoisted(() => ({
  response: { data: null as unknown, error: null as unknown },
  rpc: vi.fn(),
}));
const logs = vi.hoisted(() => ({ lines: [] as string[] }));

vi.mock('./auth', () => ({ dbFor: vi.fn(() => ({ rpc: db.rpc })) }));
vi.mock('../utils/logger', () => {
  const write = (...args: unknown[]) => {
    logs.lines.push(JSON.stringify(args));
  };
  return {
    logger: { error: write, warn: write, info: write, debug: write },
    SENSITIVE_KEYS: [],
  };
});

import { deviceContext, resolveDevice } from './deviceContext';
import { sha256Hex } from '../utils/deviceSecrets';
import { AppError } from '../utils/errors';

const DEVICE = '55555555-5555-4555-8555-555555555555';
const OTHER = '66666666-6666-4666-8666-666666666666';
const BRANCH = '44444444-4444-4444-8444-444444444444';
const TOKEN = 'Dev1ce-T0ken_'.padEnd(43, 'a');
const resolved = { device_id: DEVICE, name: 'POS-1', branch_id: BRANCH, branch_name: 'Main' };

function mockReq(headers: Record<string, string> = {}, auth = true): Request {
  return {
    headers,
    requestId: 'req-1',
    ...(auth ? { auth: { userId: 'u', email: null, accessToken: 'jwt' } } : {}),
  } as unknown as Request;
}

function run(req: Request, mw: RequestHandler = deviceContext): Promise<unknown> {
  return new Promise((resolve) => {
    const next: NextFunction = (err?: unknown) => resolve(err);
    void mw(req, {} as Response, next);
  });
}

beforeEach(() => {
  logs.lines = [];
  db.response = { data: resolved, error: null };
  db.rpc.mockReset();
  db.rpc.mockImplementation(() => Promise.resolve(db.response));
});

describe('deviceContext', () => {
  it('no device token: the request goes on without a device, and the database is not asked', async () => {
    const req = mockReq();
    expect(await run(req)).toBeUndefined();
    expect(req.device).toBeUndefined();
    expect(db.rpc).not.toHaveBeenCalled();
  });

  it('removes a device id and a token hash the client sent, with or without a token', async () => {
    const plain = mockReq({ 'x-device-id': OTHER, 'x-device-token-hash': 'f'.repeat(64) });
    await run(plain);
    expect(plain.headers['x-device-id']).toBeUndefined();
    expect(plain.headers['x-device-token-hash']).toBeUndefined();
    expect(plain.device).toBeUndefined();

    const paired = mockReq({ 'x-device-id': OTHER, 'x-device-token': TOKEN });
    await run(paired);
    expect(paired.headers['x-device-id']).toBeUndefined();
    // The device is the one the token resolved to, not the one the client named.
    expect(paired.device?.id).toBe(DEVICE);
  });

  it('a token is hashed, resolved through the caller, and only then sets req.device', async () => {
    const req = mockReq({ 'x-device-token': TOKEN });
    expect(await run(req)).toBeUndefined();
    expect(db.rpc).toHaveBeenCalledTimes(1);
    expect(db.rpc).toHaveBeenCalledWith('resolve_device', { p_token_hash: sha256Hex(TOKEN) });
    expect(JSON.stringify(db.rpc.mock.calls)).not.toContain(TOKEN);
    // The hash stays with the device: it is the proof the database asks for with the device id.
    expect(req.device).toEqual({
      id: DEVICE,
      name: 'POS-1',
      branch_id: BRANCH,
      branch_name: 'Main',
      tokenHash: sha256Hex(TOKEN),
    });
  });

  it('a token that resolves to nothing -> 403 DEVICE_REVOKED, no device', async () => {
    db.response = { data: null, error: null };
    const req = mockReq({ 'x-device-token': TOKEN });
    const err = await run(req);
    expect(err).toBeInstanceOf(AppError);
    expect(err).toMatchObject({ statusCode: 403, code: 'DEVICE_REVOKED' });
    expect(req.device).toBeUndefined();
  });

  it.each(['short', 'a'.repeat(44), `${TOKEN.slice(0, 42)}=`, 'drop table devices'])(
    'a token of the wrong shape (%s) is refused before the database is asked',
    async (bad) => {
      const req = mockReq({ 'x-device-token': bad });
      expect(await run(req)).toMatchObject({ statusCode: 403, code: 'DEVICE_REVOKED' });
      expect(db.rpc).not.toHaveBeenCalled();
    },
  );

  it('a database failure is a server error, and the log never holds the token', async () => {
    db.response = { data: null, error: { message: 'connection reset' } };
    const req = mockReq({ 'x-device-token': TOKEN });
    expect(await run(req)).toMatchObject({ statusCode: 500, code: 'INTERNAL' });
    expect(logs.lines).toHaveLength(1);
    expect(logs.lines.join('\n')).not.toContain(TOKEN);
    expect(logs.lines.join('\n')).not.toContain(sha256Hex(TOKEN));
    expect(req.device).toBeUndefined();
  });

  it('a contract error from the database keeps its code', async () => {
    db.response = { data: null, error: { message: 'SUBSCRIPTION_EXPIRED' } };
    const req = mockReq({ 'x-device-token': TOKEN });
    expect(await run(req)).toMatchObject({ statusCode: 403, code: 'SUBSCRIPTION_EXPIRED' });
  });

  it('a stale req.device never survives a request without a token', async () => {
    const req = mockReq();
    req.device = {
      id: OTHER,
      name: 'old',
      branch_id: BRANCH,
      branch_name: 'Main',
      tokenHash: 'f'.repeat(64),
    };
    await resolveDevice(req);
    expect(req.device).toBeUndefined();
  });

  it('is a programming error before authenticate', async () => {
    expect(await run(mockReq({}, false))).toBeInstanceOf(Error);
  });
});
