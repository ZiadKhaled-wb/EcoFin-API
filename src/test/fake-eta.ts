// src/test/fake-eta.ts
//
// T02: a small stand-in for the ETA for the integration tests (docs/eta/ERECEIPT_SPEC.md,
// sections 2 to 5): the token call, receipt submission, submission details and receipt lookup,
// on one local port. It checks what the real system checks and the tests rely on:
//   - the POS headers and the client credentials of the token call;
//   - every receipt's UUID, recomputed from the bytes it received (the number text as sent);
//   - the POS chain: a receipt's previousUUID is the UUID before it ("" for the first).
// It counts how many times each UUID was received, and can be told to drop the connection after
// taking a submission, to answer 5xx or 422 DuplicateSubmission, or to find a receipt Invalid.

import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import express, { type Request, type Response } from 'express';
import { receiptUuid, type HasReceiptHeader } from '../eta/uuid';
import type { EtaObject } from '../eta/serialize';
import { parseExactJson } from './eta-json';

export interface FakeEtaCredentials {
  clientId: string;
  clientSecret: string;
  posSerial: string;
  presharedKey: string;
  /** More POS devices the token call accepts (INT-4: two tills in one shop). */
  extraPos?: { posSerial: string; presharedKey: string }[];
}

export interface FakeEtaOptions {
  /** A fixed local port (the `npm run fake-eta` process); 0 or none picks a free one. */
  port?: number;
}

/** What the next submission does instead of being answered normally (used once). */
export type SubmitFault =
  /** Takes the receipts, then drops the connection: the caller can't know the outcome. */
  | 'accept-then-drop'
  /** Answers 503 and takes nothing. */
  | 'unavailable'
  /** Takes the receipts and answers 422 DuplicateSubmission with Retry-After. */
  | 'duplicate';

export interface StoredReceipt {
  uuid: string;
  previousUuid: string;
  /** header.referenceOldUUID: the rejected receipt this one corrects, '' for a first submission. */
  referenceOldUuid: string;
  receiptNumber: string;
  submissionUuid: string;
  status: 'Valid' | 'Invalid';
  reason: string | null;
  error: InvalidError | null;
  /** The receipt exactly as it was received. */
  json: string;
}

/** The ETA's complaint about one property of a receipt. */
export interface InvalidError {
  message: string;
  propertyPath?: string;
  code?: string;
}

export interface FakeEta {
  url: string;
  /** Times a receipt with this UUID arrived in a submission, whatever the answer was. */
  received: Map<string, number>;
  receipts: Map<string, StoredReceipt>;
  /** Receipts refused because their UUID is not the hash of what was sent. */
  badHashes: string[];
  /** Receipts whose previousUUID was not the UUID before them on their POS. */
  chainBreaks: string[];
  calls: { token: number; submit: number; details: number; lookup: number };
  failNextSubmit(fault: SubmitFault, retryAfterSeconds?: number): void;
  /** The next receipt taken is found Invalid with this reason (or this error on a property). */
  invalidNext(reason: string | InvalidError): void;
  /** Submission details answer InProgress this many times first. */
  inProgressFor(polls: number): void;
  close(): Promise<void>;
}

const text = (value: unknown): string => (typeof value === 'string' ? value : '');

function field(object: EtaObject, key: string): EtaObject {
  const value = object[key];
  if (typeof value !== 'object' || value === null || Array.isArray(value) || 'text' in value) {
    throw new TypeError(`receipt.${key} is not an object`);
  }
  return value as EtaObject;
}

/** Each element of the top-level `receipts` array, as the exact text between its braces. */
export function splitReceipts(body: string): string[] {
  const start = body.indexOf('[', body.indexOf('"receipts"'));
  const out: string[] = [];
  let depth = 0;
  let inString = false;
  let from = -1;
  for (let i = start + 1; i < body.length; i++) {
    const c = body[i];
    if (inString) {
      if (c === '\\') i += 1;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === '{') {
      if (depth === 0) from = i;
      depth += 1;
    } else if (c === '}') {
      depth -= 1;
      if (depth === 0) out.push(body.slice(from, i + 1));
    } else if (c === ']' && depth === 0) break;
  }
  return out;
}

export async function startFakeEta(
  credentials: FakeEtaCredentials,
  options: FakeEtaOptions = {},
): Promise<FakeEta> {
  const received = new Map<string, number>();
  const receipts = new Map<string, StoredReceipt>();
  const badHashes: string[] = [];
  const chainBreaks: string[] = [];
  const calls = { token: 0, submit: 0, details: 0, lookup: 0 };
  const tails = new Map<string, string>();
  let fault: { kind: SubmitFault; retryAfter: number } | undefined;
  let invalidReason: InvalidError | undefined;
  let inProgress = 0;
  let submissions = 0;
  const TOKEN = 'fake-eta-access-token';
  const posKeys = new Map<string, string>([
    [credentials.posSerial, credentials.presharedKey],
    ...(credentials.extraPos ?? []).map((p): [string, string] => [p.posSerial, p.presharedKey]),
  ]);

  const app = express();
  app.use(express.urlencoded({ extended: false }));
  app.use(express.text({ type: 'application/json', limit: '5mb' }));

  app.post('/connect/token', (req: Request, res: Response) => {
    calls.token += 1;
    const body = req.body as Record<string, unknown>;
    if (text(body['grant_type']) !== 'client_credentials') {
      res.status(400).json({ error: 'unsupported_grant_type' });
    } else if (
      text(body['client_id']) !== credentials.clientId ||
      text(body['client_secret']) !== credentials.clientSecret
    ) {
      res.status(400).json({ error: 'invalid_clientsecret' });
    } else if (!posKeys.has(req.header('posserial') ?? '')) {
      res.status(400).json({ error: 'invalid_posserial' });
    } else if (req.header('presharedkey') !== posKeys.get(req.header('posserial') ?? '')) {
      res.status(400).json({ error: 'invalid_presharedkey' });
    } else if (!req.header('pososversion') || !req.header('posmodelframework')) {
      res.status(400).json({ error: 'invalid_request' });
    } else {
      res.json({
        access_token: TOKEN,
        token_type: 'Bearer',
        expires_in: 3600,
        scope: 'InvoicingAPI',
      });
    }
  });

  const authorized = (req: Request, res: Response): boolean => {
    if (req.header('authorization') === `Bearer ${TOKEN}`) return true;
    res.status(401).json({ error: { code: 'Unauthorized', message: 'no token' } });
    return false;
  };

  app.post('/api/v1/receiptsubmissions', (req: Request, res: Response) => {
    if (!authorized(req, res)) return;
    calls.submit += 1;
    const now = fault;
    fault = undefined;
    if (now?.kind === 'unavailable') {
      res.status(503).json({ error: { code: 'ServiceUnavailable', message: 'try later' } });
      return;
    }

    submissions += 1;
    const submissionUuid = `FAKESUB${String(submissions).padStart(4, '0')}`;
    const accepted: object[] = [];
    const rejected: object[] = [];
    for (const json of splitReceipts(text(req.body))) {
      const receipt = parseExactJson(json) as HasReceiptHeader;
      const header = field(receipt, 'header');
      const uuid = text(header['uuid']);
      const previousUuid = text(header['previousUUID']);
      const referenceOldUuid = text(header['referenceOldUUID']);
      const receiptNumber = text(header['receiptNumber']);
      const serial = text(field(receipt, 'seller')['deviceSerialNumber']);
      received.set(uuid, (received.get(uuid) ?? 0) + 1);

      if (receiptUuid(receipt) !== uuid) {
        badHashes.push(receiptNumber);
        rejected.push({
          receiptNumber,
          uuid,
          error: {
            message: 'Validation Error',
            details: [{ code: 'BadUUID', message: 'UUID is not the hash' }],
          },
        });
        continue;
      }
      if (receipts.has(uuid)) {
        accepted.push({ uuid, longId: `LONG-${receiptNumber}`, receiptNumber });
        continue;
      }
      if (referenceOldUuid === '') {
        if ((tails.get(serial) ?? '') !== previousUuid) chainBreaks.push(receiptNumber);
        tails.set(serial, uuid);
      } else {
        // A correction keeps the previousUUID of the receipt it replaces, and takes that receipt's
        // place at the end of the chain only when that receipt was the last one.
        const old = receipts.get(referenceOldUuid);
        if (old?.status !== 'Invalid' || old.previousUuid !== previousUuid) {
          chainBreaks.push(receiptNumber);
        }
        if (tails.get(serial) === referenceOldUuid) tails.set(serial, uuid);
      }
      const reason = invalidReason ?? null;
      invalidReason = undefined;
      receipts.set(uuid, {
        uuid,
        previousUuid,
        referenceOldUuid,
        receiptNumber,
        submissionUuid,
        status: reason === null ? 'Valid' : 'Invalid',
        reason: reason === null ? null : reason.message,
        error: reason,
        json,
      });
      accepted.push({ uuid, longId: `LONG-${receiptNumber}`, receiptNumber });
    }

    if (now?.kind === 'accept-then-drop') {
      req.socket.destroy();
      return;
    }
    if (now?.kind === 'duplicate') {
      res
        .status(422)
        .set('Retry-After', String(now.retryAfter))
        .json({ error: { code: 'DuplicateSubmission', message: 'identical submission' } });
      return;
    }
    res.status(202).json({
      submissionUUID: submissionUuid,
      acceptedDocuments: accepted,
      rejectedDocuments: rejected,
    });
  });

  app.get('/api/v1/receiptsubmissions/:id/details', (req: Request, res: Response) => {
    if (!authorized(req, res)) return;
    calls.details += 1;
    const mine = [...receipts.values()].filter((r) => r.submissionUuid === req.params['id']);
    if (mine.length === 0) {
      res.status(404).json({ error: { code: 'NotFound', message: 'no such submission' } });
      return;
    }
    if (inProgress > 0) {
      inProgress -= 1;
      res.json({ status: 'InProgress', receipts: [], metadata: { totalPages: 1 } });
      return;
    }
    res.json({
      submissionuuid: req.params['id'],
      status: mine.some((r) => r.status === 'Invalid') ? 'Invalid' : 'Valid',
      receipts: mine.map((r) => ({
        uuid: r.uuid,
        receiptNumber: r.receiptNumber,
        longId: `LONG-${r.receiptNumber}`,
        status: r.status,
        errors:
          r.reason === null
            ? []
            : [
                {
                  stepId: '20',
                  stepName: 'Step 04',
                  error: {
                    code: r.error?.code ?? 'CV307',
                    ...(r.error?.propertyPath ? { propertyPath: r.error.propertyPath } : {}),
                    message: r.reason,
                  },
                },
              ],
      })),
      metadata: { totalPages: 1, totalCount: mine.length, currentPageNo: 1 },
    });
  });

  app.get('/api/v1/receipts/:uuid/raw', (req: Request, res: Response) => {
    if (!authorized(req, res)) return;
    calls.lookup += 1;
    const found = receipts.get(text(req.params['uuid']));
    if (!found) {
      res.status(404).json({ error: { code: 'NotFound', message: 'no such receipt' } });
      return;
    }
    res.json({
      submissionUUID: found.submissionUuid,
      receipt: { uuid: found.uuid, longId: `LONG-${found.receiptNumber}`, status: found.status },
    });
  });

  const server: Server = createServer(app);
  await new Promise<void>((resolve) => server.listen(options.port ?? 0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;

  return {
    url: `http://127.0.0.1:${port}`,
    received,
    receipts,
    badHashes,
    chainBreaks,
    calls,
    failNextSubmit(kind, retryAfterSeconds = 0) {
      fault = { kind, retryAfter: retryAfterSeconds };
    },
    invalidNext(reason) {
      invalidReason = typeof reason === 'string' ? { message: reason } : reason;
    },
    inProgressFor(polls) {
      inProgress = polls;
    },
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.closeAllConnections();
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}
