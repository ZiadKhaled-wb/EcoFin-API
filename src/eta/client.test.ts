import { describe, expect, it } from 'vitest';
import { createLogger } from '../utils/logger';
import { EtaClient, EtaError, etaErrorText, type EtaSession } from './client';
import type { EtaHostMap } from './config';

const HOSTS: EtaHostMap = {
  preprod: {
    idUrl: 'https://id.preprod.test',
    apiUrl: 'https://api.preprod.test',
    portalUrl: 'https://portal.preprod.test',
  },
  prod: {
    idUrl: 'https://id.prod.test',
    apiUrl: 'https://api.prod.test',
    portalUrl: 'https://portal.prod.test',
  },
};

const SECRET = 'client-secret-6d62315e';
const PRESHARED = 'preshared-key-03ac6742';
const NATIONAL_ID = '29901011234567';
const UUID = 'a'.repeat(64);
const RECEIPT = `{"header":{"uuid":"${UUID}"},"buyer":{"type":"P","id":"${NATIONAL_ID}","name":"Mona"}}`;

const session = (over: Partial<EtaSession> = {}): EtaSession => ({
  environment: 'preprod',
  deviceId: 'device-1',
  credentials: {
    clientId: 'client-id-1',
    clientSecret: SECRET,
    posSerial: 'POS-001',
    posOsVersion: 'os',
    posModelFramework: '1',
    presharedKey: PRESHARED,
  },
  ...over,
});

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

type Reply = Response | (() => Response) | Error;

/** A fetch that records every call and answers from `replies` (by "METHOD path"). */
function harness(replies: Record<string, Reply[]>) {
  const calls: Call[] = [];
  const logs: string[] = [];
  let now = Date.parse('2026-10-12T09:00:00Z');
  let tokens = 0;
  const doFetch: typeof fetch = (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const method = init?.method ?? 'GET';
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    calls.push({ url, method, headers, body: typeof init?.body === 'string' ? init.body : '' });
    const { pathname } = new URL(url);
    if (pathname === '/connect/token' && !replies['POST /connect/token']) {
      tokens += 1;
      return Promise.resolve(
        Response.json({ access_token: `token-${tokens}`, token_type: 'Bearer', expires_in: 3600 }),
      );
    }
    const reply = replies[`${method} ${pathname}`]?.shift();
    if (reply === undefined) return Promise.resolve(new Response('no reply set', { status: 599 }));
    if (reply instanceof Error) return Promise.reject(reply);
    return Promise.resolve(typeof reply === 'function' ? reply() : reply);
  };
  const client = new EtaClient({
    hosts: HOSTS,
    fetch: doFetch,
    now: () => now,
    logger: createLogger({ level: 'trace', stream: { write: (line) => logs.push(line) } }),
  });
  return {
    client,
    calls,
    logs,
    advance: (seconds: number) => {
      now += seconds * 1000;
    },
    of: (path: string) => calls.filter((call) => new URL(call.url).pathname === path),
  };
}

async function failure(promise: Promise<unknown>): Promise<EtaError> {
  try {
    await promise;
  } catch (err) {
    if (err instanceof EtaError) return err;
    throw err;
  }
  throw new Error('expected an EtaError');
}

describe('ETA client: token', () => {
  it('logs the POS in with the form body and the four POS headers', async () => {
    const h = harness({});
    expect(await h.client.token(session())).toBe('token-1');
    const [call] = h.calls;
    expect(call?.url).toBe('https://id.preprod.test/connect/token');
    expect(call?.method).toBe('POST');
    expect(call?.headers['content-type']).toBe('application/x-www-form-urlencoded');
    expect(call?.headers).toMatchObject({
      posserial: 'POS-001',
      pososversion: 'os',
      posmodelframework: '1',
      presharedkey: PRESHARED,
    });
    expect(Object.fromEntries(new URLSearchParams(call?.body))).toEqual({
      grant_type: 'client_credentials',
      client_id: 'client-id-1',
      client_secret: SECRET,
    });
  });

  it('caches the token and gets a new one 60 s before it expires', async () => {
    const h = harness({});
    expect(await h.client.token(session())).toBe('token-1');
    h.advance(3000);
    expect(await h.client.token(session())).toBe('token-1');
    h.advance(539); // 3539 s: one second before the margin
    expect(await h.client.token(session())).toBe('token-1');
    expect(h.of('/connect/token')).toHaveLength(1);
    h.advance(1); // 3540 s = expiry - 60 s
    expect(await h.client.token(session())).toBe('token-2');
    expect(h.of('/connect/token')).toHaveLength(2);
  });

  it('keeps one token per POS and per ETA system, and never crosses hosts', async () => {
    const h = harness({});
    await h.client.token(session());
    await h.client.token(session({ deviceId: 'device-2' }));
    await h.client.token(session({ environment: 'prod' }));
    await h.client.token(session());
    expect(h.calls.map((call) => new URL(call.url).host)).toEqual([
      'id.preprod.test',
      'id.preprod.test',
      'id.prod.test',
    ]);
    await h.client.lookup(session({ environment: 'prod' }), UUID).catch(() => undefined);
    expect(new URL(h.calls.at(-1)?.url ?? '').host).toBe('api.prod.test');
    expect(h.calls.at(-1)?.headers['authorization']).toBe('Bearer token-3');
  });

  it("a refused login is an auth error with the ETA's code", async () => {
    const h = harness({
      'POST /connect/token': [Response.json({ error: 'invalid_presharedkey' }, { status: 400 })],
    });
    const err = await failure(h.client.token(session()));
    expect(err.kind).toBe('auth');
    expect(err.code).toBe('invalid_presharedkey');
    expect(err.message).toBe('invalid_presharedkey');
  });

  it('`fresh` skips the cache (the connection test)', async () => {
    const h = harness({});
    await h.client.token(session());
    expect(await h.client.token(session(), { fresh: true })).toBe('token-2');
  });
});

describe('ETA client: submit', () => {
  const PATH = '/api/v1/receiptsubmissions';

  it('sends the receipt texts unchanged and reads the 202', async () => {
    const h = harness({
      [`POST ${PATH}`]: [
        Response.json(
          {
            submissionUUID: 'SUB1',
            acceptedDocuments: [{ uuid: UUID.toUpperCase(), longId: 'LONG1', receiptNumber: 'R1' }],
            rejectedDocuments: [
              {
                receiptNumber: 'R2',
                uuid: 'b'.repeat(64),
                error: {
                  message: 'Validation Error',
                  target: 'b'.repeat(64),
                  details: [
                    {
                      code: 'CF313',
                      message: 'Issuance date time value is out of the range',
                      target: 'DatetimeIssued',
                      propertyPath: 'receipts.datetimeissued',
                    },
                  ],
                },
              },
            ],
          },
          { status: 202 },
        ),
      ],
    });
    const other = '{"header":{"uuid":"x"},"total":10.50}';
    const result = await h.client.submit(session(), [RECEIPT, other], []);
    const [call] = h.of(PATH);
    expect(call?.url).toBe(`https://api.preprod.test${PATH}`);
    expect(call?.body).toBe(`{"receipts":[${RECEIPT},${other}],"signatures":[]}`);
    expect(call?.headers).toMatchObject({
      authorization: 'Bearer token-1',
      'content-type': 'application/json',
    });
    expect(result).toEqual({
      submissionUuid: 'SUB1',
      accepted: [{ uuid: UUID, longId: 'LONG1' }],
      rejected: [
        {
          uuid: 'b'.repeat(64),
          receiptNumber: 'R2',
          error:
            'Validation Error; CF313 receipts.datetimeissued Issuance date time value is out of the range',
        },
      ],
    });
  });

  it('422 DuplicateSubmission is `duplicate` with Retry-After', async () => {
    const h = harness({
      [`POST ${PATH}`]: [
        Response.json(
          { error: { code: 'DuplicateSubmission', message: 'identical submission' } },
          { status: 422, headers: { 'Retry-After': '45' } },
        ),
      ],
    });
    const err = await failure(h.client.submit(session(), [RECEIPT], []));
    expect(err).toMatchObject({
      kind: 'duplicate',
      status: 422,
      code: 'DuplicateSubmission',
      retryAfterSeconds: 45,
    });
  });

  it.each([
    [500, 'unknown'],
    [503, 'unknown'],
    [429, 'throttled'],
    [401, 'auth'],
    [400, 'rejected'],
    [403, 'rejected'],
    [422, 'rejected'],
  ] as const)('HTTP %i is `%s`', async (status, kind) => {
    const h = harness({
      [`POST ${PATH}`]: [
        Response.json({ error: { code: 'SomeCode', message: 'why' } }, { status }),
      ],
    });
    const err = await failure(h.client.submit(session(), [RECEIPT], []));
    expect(err.kind).toBe(kind);
    expect(err.status).toBe(status);
  });

  it('a timeout or network error is `unknown`: the ETA may have the receipt', async () => {
    const h = harness({
      [`POST ${PATH}`]: [
        new DOMException('The operation timed out', 'TimeoutError'),
        new TypeError('fetch failed'),
      ],
    });
    expect((await failure(h.client.submit(session(), [RECEIPT], []))).kind).toBe('unknown');
    expect((await failure(h.client.submit(session(), [RECEIPT], []))).kind).toBe('unknown');
  });

  it('a 202 that cannot be read is `unknown`, never a silent success', async () => {
    const h = harness({ [`POST ${PATH}`]: [new Response('<html>', { status: 202 })] });
    expect((await failure(h.client.submit(session(), [RECEIPT], []))).kind).toBe('unknown');
  });

  it('a 401 drops the cached token, so the next call logs in again', async () => {
    const h = harness({
      [`POST ${PATH}`]: [
        new Response('', { status: 401 }),
        Response.json({ submissionUUID: 'S', acceptedDocuments: [] }, { status: 202 }),
      ],
    });
    await failure(h.client.submit(session(), [RECEIPT], []));
    await h.client.submit(session(), [RECEIPT], []);
    expect(h.of('/connect/token')).toHaveLength(2);
    expect(h.of(PATH).map((call) => call.headers['authorization'])).toEqual([
      'Bearer token-1',
      'Bearer token-2',
    ]);
  });
});

describe('ETA client: poll and lookup', () => {
  it('reads every page of the submission details', async () => {
    const path = '/api/v1/receiptsubmissions/SUB1/details';
    const page = (uuid: string, status: string, errors?: object[]) =>
      Response.json({
        status: 'Invalid',
        receipts: [{ uuid, longId: `L-${uuid}`, status, errors }],
        metadata: { totalPages: 2, totalCount: 2, currentPageNo: 1 },
      });
    const h = harness({
      [`GET ${path}`]: [
        page('u1', 'Valid'),
        page('u2', 'Invalid', [
          {
            stepId: '20',
            error: {
              propertyPath: '$.itemData[*].itemCode',
              errorCode: 'CV307',
              error: `Buyer ${NATIONAL_ID} not valid`,
            },
          },
        ]),
      ],
    });
    const details = await h.client.submissionDetails(session(), 'SUB1');
    expect(h.of(path).map((call) => new URL(call.url).search)).toEqual([
      '?PageNo=1&PageSize=50',
      '?PageNo=2&PageSize=50',
    ]);
    expect(details).toEqual({
      status: 'invalid',
      receipts: [
        { uuid: 'u1', longId: 'L-u1', status: 'valid', error: null },
        {
          uuid: 'u2',
          longId: 'L-u2',
          status: 'invalid',
          error: 'CV307 $.itemData[*].itemCode Buyer [national-id] not valid',
        },
      ],
    });
  });

  it('an in-progress submission is reported as such', async () => {
    const h = harness({
      'GET /api/v1/receiptsubmissions/SUB2/details': [
        Response.json({ status: 'InProgress', receipts: [] }),
      ],
    });
    expect(await h.client.submissionDetails(session(), 'SUB2')).toEqual({
      status: 'inprogress',
      receipts: [],
    });
  });

  it('lookup: the receipt as the ETA has it, or null when it has none', async () => {
    const path = `/api/v1/receipts/${UUID}/raw`;
    const h = harness({
      [`GET ${path}`]: [
        Response.json({ submissionUUID: 'SUB1', receipt: { longId: 'LONG1', status: 'Valid' } }),
        Response.json({ error: { code: 'NotFound', message: 'no' } }, { status: 404 }),
        new Response('', { status: 503 }),
      ],
    });
    expect(await h.client.lookup(session(), UUID)).toEqual({
      submissionUuid: 'SUB1',
      longId: 'LONG1',
      status: 'valid',
    });
    expect(await h.client.lookup(session(), UUID)).toBeNull();
    expect((await failure(h.client.lookup(session(), UUID))).kind).toBe('unknown');
  });
});

describe('ETA client: nothing sensitive in the logs or the errors', () => {
  it('logs no secret, key, token or receipt body, whatever happens', async () => {
    const PATH = '/api/v1/receiptsubmissions';
    const h = harness({
      [`POST ${PATH}`]: [
        Response.json(
          { submissionUUID: 'S', acceptedDocuments: [{ uuid: UUID }] },
          { status: 202 },
        ),
        Response.json(
          { error: { code: 'BadStructure', message: `buyer ${NATIONAL_ID} is not valid` } },
          { status: 400 },
        ),
        new Response('', { status: 500 }),
        new TypeError(`fetch failed for ${SECRET}`),
      ],
      [`GET /api/v1/receipts/${UUID}/raw`]: [new Response('', { status: 404 })],
    });
    await h.client.submit(session(), [RECEIPT], []);
    const refused = await failure(h.client.submit(session(), [RECEIPT], []));
    await failure(h.client.submit(session(), [RECEIPT], []));
    const unreachable = await failure(h.client.submit(session(), [RECEIPT], []));
    await h.client.lookup(session(), UUID);

    expect(h.logs.length).toBeGreaterThanOrEqual(6);
    const all = h.logs.join('\n');
    for (const hidden of [
      SECRET,
      PRESHARED,
      'token-1',
      'Bearer',
      NATIONAL_ID,
      'Mona',
      'client-id-1',
    ]) {
      expect(all).not.toContain(hidden);
    }
    // A log line says which call, where and how it ended.
    expect(JSON.parse(h.logs[0] ?? '{}')).toMatchObject({
      component: 'eta',
      etaCall: 'token',
      environment: 'preprod',
      status: 200,
    });
    expect(all).toContain('"code":"BadStructure"');

    // The ETA's own text is masked before it leaves the client (it goes into last_error).
    expect(refused.message).toBe('BadStructure buyer [national-id] is not valid');
    expect(refused.message).not.toContain(NATIONAL_ID);
    expect(unreachable.message).not.toContain(SECRET);
  });

  it('etaErrorText masks national IDs at every level and stays short', () => {
    const text = etaErrorText({
      code: 'X1',
      message: `id ${NATIONAL_ID}`,
      details: [{ errorCode: 'X2', error: `again ${NATIONAL_ID}`, innerError: { error: 'deep' } }],
    });
    expect(text).toBe('X1 id [national-id]; X2 again [national-id]; deep');
    expect(etaErrorText({ message: 'x'.repeat(5000) }).length).toBe(1500);
    expect(etaErrorText(null)).toBe('');
  });
});
