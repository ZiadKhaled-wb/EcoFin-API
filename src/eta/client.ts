// server/src/eta/client.ts
//
// T02 (D67). The four ETA calls (docs/eta/ERECEIPT_SPEC.md, sections 2 to 5): token, submit,
// submission details, receipt lookup by UUID. Node's own fetch, 15 s per call.
//
// Every failure is an EtaError whose `kind` says what the caller may do next:
//   unknown    timeout, network error or 5xx: the ETA may or may not have the request
//   duplicate  422 DuplicateSubmission: the same payload in the last 10 minutes (Retry-After)
//   throttled  429: not processed; wait Retry-After
//   auth       the token call refused the credentials, or a call answered 401
//   rejected   any other 4xx: the request itself is wrong; sending it again changes nothing
//
// Secrets, tokens and receipt bodies are never logged or put in an error: a log line carries
// the call's name, the environment, the HTTP status and the ETA's error code only. Text that
// comes from the ETA is masked (a validation message can quote a buyer's national ID).

import type { EtaEnvironment } from '@ziadkhaled-wb/contracts';
import type { Logger } from 'pino';
import { z } from 'zod';
import { maskText } from '../utils/monitoring';
import type { EtaHostMap } from './config';
import type { EtaSignature } from './signer';

export type EtaErrorKind = 'unknown' | 'duplicate' | 'throttled' | 'auth' | 'rejected';

export class EtaError extends Error {
  readonly kind: EtaErrorKind;
  readonly status: number | undefined;
  /** The ETA's own error code (`DuplicateSubmission`, `invalid_presharedkey`, ...). */
  readonly code: string | undefined;
  readonly retryAfterSeconds: number | undefined;

  constructor(
    kind: EtaErrorKind,
    message: string,
    details: { status?: number; code?: string; retryAfterSeconds?: number } = {},
  ) {
    super(message);
    Object.setPrototypeOf(this, EtaError.prototype);
    this.name = 'EtaError';
    this.kind = kind;
    this.status = details.status;
    this.code = details.code;
    this.retryAfterSeconds = details.retryAfterSeconds;
  }
}

/** What the token call needs for one POS. Never logged. */
export interface EtaCredentials {
  clientId: string;
  clientSecret: string;
  posSerial: string;
  posOsVersion: string;
  posModelFramework: string;
  presharedKey: string;
}

/** One POS of one shop on one ETA system. */
export interface EtaSession {
  environment: EtaEnvironment;
  deviceId: string;
  credentials: EtaCredentials;
}

export interface SubmitResult {
  submissionUuid: string | null;
  accepted: { uuid: string; longId: string | null }[];
  rejected: { uuid: string | null; receiptNumber: string | null; error: string }[];
}

export type DocumentStatus = 'valid' | 'invalid' | 'cancelled' | 'other';

export interface SubmissionDetails {
  /** The whole submission. */
  status: 'inprogress' | 'valid' | 'invalid' | 'other';
  receipts: { uuid: string; longId: string | null; status: DocumentStatus; error: string | null }[];
}

export interface LookupResult {
  submissionUuid: string | null;
  longId: string | null;
  status: DocumentStatus;
}

/** The calls the jobs make: what a test stands in for. */
export type EtaApi = Pick<EtaClient, 'token' | 'submit' | 'submissionDetails' | 'lookup'>;

export interface EtaClientOptions {
  hosts: EtaHostMap;
  logger: Logger;
  fetch?: typeof fetch;
  /** Milliseconds since the epoch; tests move the clock. */
  now?: () => number;
  timeoutMs?: number;
}

/** A token is used until this long before it expires. */
const TOKEN_MARGIN_MS = 60_000;
const DETAILS_PAGE_SIZE = 50;
const MAX_DETAILS_PAGES = 20;

const text = z.string().nullish();

const TokenResponse = z.object({
  access_token: z.string().min(1),
  expires_in: z.coerce.number().positive(),
});

interface EtaErrorBody {
  code?: string | null | undefined;
  message?: string | null | undefined;
  error?: string | null | undefined;
  errorCode?: string | null | undefined;
  target?: string | null | undefined;
  propertyPath?: string | null | undefined;
  details?: EtaErrorBody[] | null | undefined;
  innerError?: EtaErrorBody | EtaErrorBody[] | null | undefined;
}

const ErrorBody: z.ZodType<EtaErrorBody> = z.lazy(() =>
  z.object({
    code: text,
    message: text,
    error: text,
    errorCode: text,
    target: text,
    propertyPath: text,
    details: z.array(ErrorBody).nullish(),
    innerError: z.union([ErrorBody, z.array(ErrorBody)]).nullish(),
  }),
);

const SubmitResponse = z.object({
  submissionUUID: text,
  acceptedDocuments: z.array(z.object({ uuid: z.string(), longId: text })).nullish(),
  rejectedDocuments: z
    .array(z.object({ uuid: text, receiptNumber: text, error: ErrorBody.nullish() }))
    .nullish(),
});

const DetailsResponse = z.object({
  status: text,
  receipts: z
    .array(
      z.object({
        uuid: z.string(),
        longId: text,
        status: text,
        errors: z.array(z.object({ error: ErrorBody.nullish() })).nullish(),
      }),
    )
    .nullish(),
  metadata: z.object({ totalPages: z.coerce.number().nullish() }).nullish(),
});

const LookupResponse = z.object({
  submissionUUID: text,
  receipt: z.object({ longId: text, status: text }).nullish(),
});

/** The ETA's error as one masked line: `CF313 receipts.datetimeissued: Issuance date ...`. */
export function etaErrorText(error: EtaErrorBody | null | undefined, depth = 0): string {
  if (!error || depth > 3) return '';
  const head = [error.code ?? error.errorCode, error.propertyPath, error.message ?? error.error]
    .filter((part): part is string => typeof part === 'string' && part !== '')
    .join(' ');
  const inner = Array.isArray(error.innerError)
    ? error.innerError
    : error.innerError
      ? [error.innerError]
      : [];
  const nested = [...(error.details ?? []), ...inner]
    .map((child) => etaErrorText(child, depth + 1))
    .filter((part) => part !== '');
  return maskText([head, ...nested].filter((part) => part !== '').join('; ')).slice(0, 1500);
}

function documentStatus(value: string | null | undefined): DocumentStatus {
  const status = (value ?? '').toLowerCase();
  return status === 'valid' || status === 'invalid' || status === 'cancelled' ? status : 'other';
}

/** Seconds from a Retry-After header (a number of seconds, or a date). */
function retryAfter(response: Response, now: number): number | undefined {
  const raw = response.headers.get('retry-after');
  if (raw === null || raw.trim() === '') return undefined;
  if (/^\d+$/.test(raw.trim())) return Number(raw.trim());
  const at = Date.parse(raw);
  return Number.isNaN(at) ? undefined : Math.max(0, Math.ceil((at - now) / 1000));
}

export class EtaClient {
  private readonly hosts: EtaHostMap;
  private readonly log: Logger;
  private readonly doFetch: typeof fetch;
  private readonly now: () => number;
  private readonly timeoutMs: number;
  /** In memory only, per ETA system and POS. */
  private readonly tokens = new Map<string, { token: string; expiresAt: number }>();

  constructor(options: EtaClientOptions) {
    this.hosts = options.hosts;
    this.log = options.logger.child({ component: 'eta' });
    this.doFetch = options.fetch ?? fetch;
    this.now = options.now ?? Date.now;
    this.timeoutMs = options.timeoutMs ?? 15_000;
  }

  /** The POS's access token: the cached one until 60 s before it expires, else a new one. */
  async token(session: EtaSession, options: { fresh?: boolean } = {}): Promise<string> {
    const key = `${session.environment}:${session.deviceId}`;
    const cached = this.tokens.get(key);
    if (!options.fresh && cached && cached.expiresAt - TOKEN_MARGIN_MS > this.now()) {
      return cached.token;
    }
    this.tokens.delete(key);

    const c = session.credentials;
    const response = await this.send('token', session.environment, 'id', '/connect/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
        posserial: c.posSerial,
        pososversion: c.posOsVersion,
        posmodelframework: c.posModelFramework,
        presharedkey: c.presharedKey,
      },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: c.clientId,
        client_secret: c.clientSecret,
      }).toString(),
    });
    if (!response.ok) {
      const body = await this.json(response);
      const code = z.object({ error: z.string() }).safeParse(body);
      throw this.failure('token', session.environment, response, {
        kind: response.status >= 500 ? 'unknown' : 'auth',
        code: code.success ? code.data.error : undefined,
      });
    }
    const parsed = TokenResponse.safeParse(await this.json(response));
    if (!parsed.success) {
      throw new EtaError('unknown', 'The ETA token answer could not be read', {
        status: response.status,
      });
    }
    this.tokens.set(key, {
      token: parsed.data.access_token,
      expiresAt: this.now() + parsed.data.expires_in * 1000,
    });
    return parsed.data.access_token;
  }

  /**
   * One submission. `receiptsJson` holds each receipt's JSON text exactly as it was hashed: the
   * body is put together from those texts, never parsed and written again.
   */
  async submit(
    session: EtaSession,
    receiptsJson: readonly string[],
    signatures: readonly EtaSignature[],
  ): Promise<SubmitResult> {
    const body = `{"receipts":[${receiptsJson.join(',')}],"signatures":${JSON.stringify(signatures)}}`;
    const response = await this.call('submit', session, '/api/v1/receiptsubmissions', {
      method: 'POST',
      body,
    });
    if (response.status !== 202 && response.status !== 200) {
      const error = await this.errorBody(response);
      const duplicate = response.status === 422 && error.code === 'DuplicateSubmission';
      throw this.failure('submit', session.environment, response, {
        kind: duplicate ? 'duplicate' : undefined,
        code: error.code,
        text: error.text,
      });
    }
    const parsed = SubmitResponse.safeParse(await this.json(response));
    if (!parsed.success) {
      // Received, but the answer can't be read: the receipts are looked up before any resend.
      throw new EtaError('unknown', 'The ETA submit answer could not be read', {
        status: response.status,
      });
    }
    return {
      submissionUuid: parsed.data.submissionUUID ?? null,
      accepted: (parsed.data.acceptedDocuments ?? []).map((d) => ({
        uuid: d.uuid.toLowerCase(),
        longId: d.longId ?? null,
      })),
      rejected: (parsed.data.rejectedDocuments ?? []).map((d) => ({
        uuid: d.uuid?.toLowerCase() ?? null,
        receiptNumber: d.receiptNumber ?? null,
        error: etaErrorText(d.error) || 'rejected without a reason',
      })),
    };
  }

  /** The result of one submission, every page of it. */
  async submissionDetails(session: EtaSession, submissionUuid: string): Promise<SubmissionDetails> {
    const receipts: SubmissionDetails['receipts'] = [];
    let status: SubmissionDetails['status'] = 'other';
    for (let page = 1; page <= MAX_DETAILS_PAGES; page++) {
      const path =
        `/api/v1/receiptsubmissions/${encodeURIComponent(submissionUuid)}/details` +
        `?PageNo=${page}&PageSize=${DETAILS_PAGE_SIZE}`;
      const response = await this.call('details', session, path, { method: 'GET' });
      if (!response.ok) {
        const error = await this.errorBody(response);
        throw this.failure('details', session.environment, response, error);
      }
      const parsed = DetailsResponse.safeParse(await this.json(response));
      if (!parsed.success) {
        throw new EtaError('unknown', 'The ETA submission details could not be read', {
          status: response.status,
        });
      }
      const overall = (parsed.data.status ?? '').toLowerCase();
      status =
        overall === 'inprogress' || overall === 'valid' || overall === 'invalid'
          ? overall
          : 'other';
      for (const r of parsed.data.receipts ?? []) {
        const error = (r.errors ?? []).map((e) => etaErrorText(e.error)).filter((t) => t !== '');
        receipts.push({
          uuid: r.uuid.toLowerCase(),
          longId: r.longId ?? null,
          status: documentStatus(r.status),
          error: error.length > 0 ? error.join('; ').slice(0, 1500) : null,
        });
      }
      if (page >= (parsed.data.metadata?.totalPages ?? 1)) break;
    }
    return { status, receipts };
  }

  /** The receipt with this UUID as the ETA has it, or null when it has none. */
  async lookup(session: EtaSession, uuid: string): Promise<LookupResult | null> {
    const path = `/api/v1/receipts/${encodeURIComponent(uuid)}/raw`;
    const response = await this.call('lookup', session, path, { method: 'GET' });
    if (response.status === 404) return null;
    if (!response.ok) {
      const error = await this.errorBody(response);
      throw this.failure('lookup', session.environment, response, error);
    }
    const parsed = LookupResponse.safeParse(await this.json(response));
    if (!parsed.success) {
      throw new EtaError('unknown', 'The ETA receipt answer could not be read', {
        status: response.status,
      });
    }
    return {
      submissionUuid: parsed.data.submissionUUID ?? null,
      longId: parsed.data.receipt?.longId ?? null,
      status: documentStatus(parsed.data.receipt?.status),
    };
  }

  /** An authenticated call. A 401 drops the cached token, so the next call logs in again. */
  private async call(
    name: string,
    session: EtaSession,
    path: string,
    init: { method: string; body?: string },
  ): Promise<Response> {
    const token = await this.token(session);
    const response = await this.send(name, session.environment, 'api', path, {
      method: init.method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
        'Accept-Language': 'en',
        ...(init.body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      ...(init.body === undefined ? {} : { body: init.body }),
    });
    if (response.status === 401) this.tokens.delete(`${session.environment}:${session.deviceId}`);
    return response;
  }

  private async send(
    name: string,
    environment: EtaEnvironment,
    host: 'id' | 'api',
    path: string,
    init: RequestInit,
  ): Promise<Response> {
    const hosts = this.hosts[environment];
    const url = (host === 'id' ? hosts.idUrl : hosts.apiUrl) + path;
    const started = this.now();
    try {
      const response = await this.doFetch(url, {
        ...init,
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      this.log.info(
        { etaCall: name, environment, status: response.status, ms: this.now() - started },
        'ETA call',
      );
      return response;
    } catch (err) {
      const reason = err instanceof Error ? err.name : 'error';
      this.log.warn(
        { etaCall: name, environment, reason, ms: this.now() - started },
        'ETA call failed',
      );
      throw new EtaError('unknown', `The ETA could not be reached (${reason})`);
    }
  }

  private async json(response: Response): Promise<unknown> {
    try {
      const body: unknown = await response.json();
      return body;
    } catch {
      return undefined;
    }
  }

  private async errorBody(response: Response): Promise<{ code: string | undefined; text: string }> {
    const parsed = z.object({ error: ErrorBody }).safeParse(await this.json(response));
    if (!parsed.success) return { code: undefined, text: '' };
    return { code: parsed.data.error.code ?? undefined, text: etaErrorText(parsed.data.error) };
  }

  private failure(
    name: string,
    environment: EtaEnvironment,
    response: Response,
    info: { kind?: EtaErrorKind | undefined; code?: string | undefined; text?: string },
  ): EtaError {
    const status = response.status;
    const kind: EtaErrorKind =
      info.kind ??
      (status >= 500
        ? 'unknown'
        : status === 429
          ? 'throttled'
          : status === 401
            ? 'auth'
            : 'rejected');
    const seconds = retryAfter(response, this.now());
    this.log.warn(
      { etaCall: name, environment, status, code: info.code, kind },
      'ETA call refused',
    );
    const detail = info.text || info.code || `HTTP ${status}`;
    return new EtaError(kind, maskText(detail).slice(0, 1500), {
      status,
      ...(info.code === undefined ? {} : { code: info.code }),
      ...(seconds === undefined ? {} : { retryAfterSeconds: seconds }),
    });
  }
}
