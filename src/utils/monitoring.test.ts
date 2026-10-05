import { describe, expect, it, vi, beforeEach } from 'vitest';
import type { ErrorEvent } from '@sentry/node';

// The SDK is replaced: these tests check what we hand to Sentry, never the network.
const sentry = vi.hoisted(() => {
  const scope = { setTag: vi.fn(), setLevel: vi.fn(), setExtras: vi.fn() };
  return {
    scope,
    initWithoutDefaultIntegrations: vi.fn(),
    getDefaultIntegrationsWithoutPerformance: vi.fn(() => [
      { name: 'InboundFilters' },
      { name: 'OnUnhandledRejection' },
    ]),
    onUnhandledRejectionIntegration: vi.fn((opts: unknown) => ({
      name: 'OnUnhandledRejection',
      opts,
    })),
    withScope: vi.fn((fn: (s: typeof scope) => unknown) => fn(scope)),
    captureException: vi.fn(() => 'event-id-1'),
    captureMessage: vi.fn(() => 'event-id-2'),
    close: vi.fn(() => Promise.resolve(true)),
  };
});
vi.mock('@sentry/node', () => sentry);

const config = { NODE_ENV: 'production', SERVICE_NAME: 'ecofin-api' };

async function load() {
  vi.resetModules();
  return import('./monitoring');
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe('monitoring off (no SENTRY_DSN)', () => {
  it('starts nothing and sends nothing', async () => {
    const m = await load();
    expect(m.initMonitoring(config)).toBe(false);
    expect(m.captureServerError(new Error('x'), { requestId: 'r1' })).toBeUndefined();
    expect(m.captureProblem('x', { problem: 'job.dead' })).toBeUndefined();
    await m.flushMonitoring();
    expect(sentry.initWithoutDefaultIntegrations).not.toHaveBeenCalled();
    expect(sentry.captureException).not.toHaveBeenCalled();
    expect(sentry.close).not.toHaveBeenCalled();
  });
});

describe('monitoring on', () => {
  it('errors only, no PII, no breadcrumbs, strict unhandled rejections, environment and release', async () => {
    const m = await load();
    expect(
      m.initMonitoring({
        ...config,
        SENTRY_DSN: 'https://k@o1.ingest.sentry.io/2',
        SENTRY_ENVIRONMENT: 'development',
        APP_RELEASE: 'sha-abc1234',
      }),
    ).toBe(true);
    const options = sentry.initWithoutDefaultIntegrations.mock.calls[0]?.[0] as Record<
      string,
      unknown
    >;
    expect(options).toMatchObject({
      dsn: 'https://k@o1.ingest.sentry.io/2',
      environment: 'development',
      release: 'sha-abc1234',
      dataCollection: {
        userInfo: false,
        cookies: false,
        httpHeaders: false,
        httpBodies: [],
        urlQueryParams: false,
        databaseQueryData: false,
        queues: false,
        stackFrameVariables: false,
      },
      maxBreadcrumbs: 0,
      initialScope: { tags: { service: 'ecofin-api' } },
    });
    expect(options['tracesSampleRate']).toBeUndefined();
    expect(sentry.onUnhandledRejectionIntegration).toHaveBeenCalledWith({ mode: 'strict' });
    const names = (options['integrations'] as { name: string; opts?: unknown }[]).map(
      (i) => i.opts ?? i.name,
    );
    expect(names).toEqual(['InboundFilters', { mode: 'strict' }]);
  });

  it('a server error is captured with the request id and route tags; undefined tags are skipped', async () => {
    const m = await load();
    m.initMonitoring({ ...config, SENTRY_DSN: 'https://k@o1.ingest.sentry.io/2' });
    const err = new Error('boom');
    expect(
      m.captureServerError(err, {
        requestId: 'req-123',
        orgId: 'org-1',
        method: 'POST',
        route: '/api/monitoring/test-error',
        code: 'INTERNAL',
        userId: undefined,
      }),
    ).toBe('event-id-1');
    expect(sentry.captureException).toHaveBeenCalledWith(err);
    expect(sentry.scope.setTag.mock.calls).toEqual([
      ['requestId', 'req-123'],
      ['orgId', 'org-1'],
      ['method', 'POST'],
      ['route', '/api/monitoring/test-error'],
      ['code', 'INTERNAL'],
    ]);
  });

  it('a job problem is captured as an error with string tags and extras', async () => {
    const m = await load();
    m.initMonitoring({ ...config, SENTRY_DSN: 'https://k@o1.ingest.sentry.io/2' });
    m.captureProblem(
      'ledger mismatch',
      { problem: 'ledger.mismatch', count: 2, orgId: null },
      { a: 1 },
    );
    expect(sentry.scope.setLevel).toHaveBeenCalledWith('error');
    expect(sentry.scope.setTag.mock.calls).toEqual([
      ['problem', 'ledger.mismatch'],
      ['count', '2'],
    ]);
    expect(sentry.scope.setExtras).toHaveBeenCalledWith({ a: 1 });
    expect(sentry.captureMessage).toHaveBeenCalledWith('ledger mismatch', 'error');
  });
});

describe('scrubbing', () => {
  it('masks emails, national ids, phones, bearer tokens and JWTs in text', async () => {
    const { maskText } = await load();
    expect(
      maskText(
        'user a.b+c@shop.example.com id 29001011234567 phone 01012345678 / +201112345678 ' +
          'Bearer abc.def-123 token eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl',
      ),
    ).toBe('user [email] id [national-id] phone [phone] / [phone] Bearer [token] token [jwt]');
  });

  it('masks tokens and codes in URLs', async () => {
    const { maskText } = await load();
    expect(maskText('GET /verify?token=abc123&type=recovery#access_token=x&refresh_token=y')).toBe(
      'GET /verify?token=[redacted]&type=recovery#access_token=[redacted]&refresh_token=[redacted]',
    );
  });

  it('leaves ids, amounts and request ids alone', async () => {
    const { maskText } = await load();
    const text = 'shop d1000000-0000-0000-0000-000000000001 total 1250.50 request 1f3a9c2e';
    expect(maskText(text)).toBe(text);
  });

  it('drops request, user and breadcrumbs, and scrubs messages, extras, contexts and tags', async () => {
    const { scrubEvent } = await load();
    const event = {
      type: undefined,
      message: 'failed for a@b.co',
      request: { headers: { authorization: 'Bearer x' }, data: { password: 'p' } },
      user: { email: 'a@b.co' },
      breadcrumbs: [{ message: 'GET /x?email=a@b.co' }],
      exception: {
        values: [{ type: 'Error', value: 'duplicate key (national_id)=(29001011234567)' }],
      },
      extra: {
        password: 'secret',
        nested: { nationalId: '29001011234567', note: 'call 01012345678' },
      },
      contexts: { job: { accessToken: 'abc' } },
      tags: { requestId: 'req-1' },
    } as unknown as ErrorEvent;
    const out = scrubEvent(event);
    expect(out.request).toBeUndefined();
    expect(out.user).toBeUndefined();
    expect(out.breadcrumbs).toBeUndefined();
    expect(out.message).toBe('failed for [email]');
    expect(out.exception?.values?.[0]?.value).toBe('duplicate key (national_id)=([national-id])');
    expect(out.extra).toEqual({
      password: '[Redacted]',
      nested: { nationalId: '[Redacted]', note: 'call [phone]' },
    });
    expect(out.contexts).toEqual({ job: { accessToken: '[Redacted]' } });
    expect(out.tags).toEqual({ requestId: 'req-1' });
  });
});
