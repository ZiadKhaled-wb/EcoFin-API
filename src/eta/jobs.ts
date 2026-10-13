// server/src/eta/jobs.ts
//
// T02 (D67, decisions 5 to 7). The three ETA job types, run by the F13 worker:
//   eta.prepare  builds what is pending for a POS (prepare.ts)
//   eta.submit   sends the prepared receipts of a POS that are due, oldest first, in batches
//   eta.poll     reads the result of one submission: Valid -> accepted, Invalid -> rejected
// The database queues the follow-up job with each status change (public.eta_store_prepared and
// public.eta_mark), so the handlers queue only the next poll.
//
// Never twice:
//   - a receipt is leased while it is being sent (public.eta_claim_for_submit), so two workers
//     can't send it at the same time;
//   - a receipt that was sent before (or leased by a worker that died) is first looked up at the
//     ETA by its UUID: found means it is there, and it moves to 'submitted' without a resend;
//   - 422 DuplicateSubmission: wait for Retry-After, then the same lookup.
//
// A failed send is not a failed job: the receipt stays pending and is due again after a wait
// (1 min, 5 min, 15 min, 1 h, then every 2 h), and the job ends well. A job fails (and F13
// retries it, then alerts) only on something unexpected, such as the database being down.

import type { Logger } from 'pino';
import type { Job, JobHandler } from '../jobs/types';
import { captureProblem } from '../utils/monitoring';
import { EtaError, type EtaApi, type EtaSession } from './client';
import { prepareDevice, type PrepareDeps } from './prepare';
import { noSignature, type ReceiptSigner } from './signer';
import type { CredentialsRow, SubmitRow } from './store';

export interface EtaJobOptions extends PrepareDeps {
  client: EtaApi;
  signer?: ReceiptSigner;
  /** The clock; tests move it. */
  now?: () => Date;
  /** Receipts per submission (the ETA takes 500; default 50). */
  batchSize?: number;
  /** Bytes per submission (the ETA takes 1.5 MB; default 1.4 MB). */
  maxBatchBytes?: number;
  /** Waits after a failed send, by how many sends failed before. The last one repeats. */
  retryDelaysSeconds?: readonly number[];
  /** Waits before poll 1, 2, 3 ... of a submission. The last one repeats. */
  pollDelaysSeconds?: readonly number[];
  /** Polls of one submission before giving up with an alert. */
  maxPolls?: number;
  /** Pause between two lookups (the ETA allows 2 per second). */
  lookupGapMs?: number;
  /** A receipt still pending this long after its sale alerts once (the ETA's limit is 24 h). */
  deadlineHours?: number;
  /** How long a receipt is held for one send before another worker may take it. */
  leaseSeconds?: number;
}

export const ETA_RETRY_DELAYS_SECONDS = [60, 300, 900, 3600, 7200] as const;
export const ETA_POLL_DELAYS_SECONDS = [30, 120, 600, 1800] as const;

/** Batches of one eta.submit run; what is left is picked up by the next job. */
const MAX_ROUNDS = 10;

const sleep = (ms: number): Promise<void> =>
  ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve();

/** The wait at position `index`; past the end, the last one. */
function delayAt(delays: readonly number[], index: number): number {
  return delays[Math.min(Math.max(index, 0), delays.length - 1)] ?? 0;
}

function text(payload: Record<string, unknown>, key: string): string | null {
  const value = payload[key];
  return typeof value === 'string' && value !== '' ? value : null;
}

/** The credentials as a session, or why the POS can't log in. */
function sessionOf(
  deviceId: string,
  row: CredentialsRow | null,
): { session: EtaSession } | { problem: string } {
  if (!row) return { problem: 'the POS does not belong to the shop' };
  if (!row.device_active || row.device_status !== 'active') {
    return { problem: 'the POS is not active with the ETA' };
  }
  const {
    client_id,
    client_secret,
    pos_serial,
    pos_os_version,
    pos_model_framework,
    preshared_key,
  } = row;
  if (!client_id || !client_secret) return { problem: 'the shop has no ETA client id or secret' };
  if (!pos_serial || !pos_os_version || !pos_model_framework || !preshared_key) {
    return { problem: 'the POS registration is incomplete' };
  }
  return {
    session: {
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
  };
}

/** Rows grouped so that no submission passes the byte limit (a single big receipt goes alone). */
export function batchesBySize(rows: readonly SubmitRow[], maxBytes: number): SubmitRow[][] {
  const batches: SubmitRow[][] = [];
  let current: SubmitRow[] = [];
  let size = 0;
  for (const row of rows) {
    const bytes = Buffer.byteLength(row.receipt_json, 'utf8') + 1;
    if (current.length > 0 && size + bytes > maxBytes) {
      batches.push(current);
      current = [];
      size = 0;
    }
    current.push(row);
    size += bytes;
  }
  if (current.length > 0) batches.push(current);
  return batches;
}

export function etaJobHandlers(
  options: EtaJobOptions,
): Record<'eta.prepare' | 'eta.submit' | 'eta.poll', JobHandler> {
  const { store, client } = options;
  const signer = options.signer ?? noSignature;
  const now = options.now ?? (() => new Date());
  const batchSize = options.batchSize ?? 50;
  const maxBatchBytes = options.maxBatchBytes ?? 1_400_000;
  const retryDelays = options.retryDelaysSeconds ?? ETA_RETRY_DELAYS_SECONDS;
  const pollDelays = options.pollDelaysSeconds ?? ETA_POLL_DELAYS_SECONDS;
  const maxPolls = options.maxPolls ?? 60;
  const lookupGapMs = options.lookupGapMs ?? 600;
  const deadlineHours = options.deadlineHours ?? 20;
  const leaseSeconds = options.leaseSeconds ?? 300;

  function alert(
    log: Logger,
    reason: string,
    tags: Record<string, string | number | null | undefined>,
  ): void {
    log.error({ reason, ...tags }, 'eta.failed');
    captureProblem(`eta.failed: ${reason}`, { problem: 'eta.failed', reason, ...tags });
  }

  function orgOf(job: Job): string {
    if (!job.organizationId) throw new Error(`${job.type} needs a shop`);
    return job.organizationId;
  }

  /** A send that failed: what the receipt becomes, by what the ETA's answer allows next. */
  async function failed(row: SubmitRow, err: EtaError, log: Logger): Promise<void> {
    if (err.kind === 'rejected') {
      await store.mark(row.fiscal_id, 'rejected', { last_error: `ETA_REJECTED: ${err.message}` });
      alert(log, 'rejected', {
        orgId: row.organization_id,
        fiscalId: row.fiscal_id,
        receipt: row.internal_id,
      });
      return;
    }
    const backoff = delayAt(retryDelays, row.attempts);
    const code =
      err.kind === 'duplicate'
        ? 'ETA_DUPLICATE'
        : err.kind === 'throttled'
          ? 'ETA_THROTTLED'
          : err.kind === 'auth'
            ? 'ETA_AUTH'
            : 'ETA_UNREACHABLE';
    // Duplicate and throttled answers say how long to wait: at least that long.
    const wait =
      err.kind === 'duplicate'
        ? (err.retryAfterSeconds ?? 600) + 1
        : err.kind === 'throttled'
          ? Math.max((err.retryAfterSeconds ?? 0) + 1, backoff)
          : backoff;
    await store.mark(row.fiscal_id, 'pending', {
      last_error: `${code}: ${err.message}`,
      retry_in_seconds: wait,
    });
    if (err.kind === 'auth' && row.attempts === 0) {
      alert(log, 'auth', { orgId: row.organization_id, fiscalId: row.fiscal_id, code: err.code });
    }
  }

  /** The ETA has this receipt: it moves on without being sent (again). */
  async function found(
    row: SubmitRow,
    hit: { submissionUuid: string | null; longId: string | null; status: string },
    log: Logger,
  ): Promise<void> {
    await store.mark(row.fiscal_id, 'submitted', {
      eta_long_id: hit.longId,
      eta_submission_uuid: hit.submissionUuid,
      poll_in_seconds: delayAt(pollDelays, 0),
    });
    if (hit.submissionUuid !== null) return;
    // Without a submission there is nothing to poll: the receipt's own status decides.
    if (hit.status === 'valid') await store.mark(row.fiscal_id, 'accepted');
    else if (hit.status === 'invalid') {
      await store.mark(row.fiscal_id, 'rejected', { last_error: 'ETA_INVALID: no reason given' });
      alert(log, 'invalid', {
        orgId: row.organization_id,
        fiscalId: row.fiscal_id,
        receipt: row.internal_id,
      });
    } else {
      alert(log, 'no_submission', { orgId: row.organization_id, fiscalId: row.fiscal_id });
    }
  }

  const prepare: JobHandler = async (job, log) => {
    orgOf(job);
    const done = await prepareDevice(
      { store, hosts: options.hosts, logger: log },
      { deviceId: text(job.payload, 'device_id'), branchId: text(job.payload, 'branch_id') },
    );
    log.info({ prepared: done.prepared, blocked: done.blocked }, 'eta.prepare done');
  };

  const submit: JobHandler = async (job, log) => {
    const orgId = orgOf(job);
    const deviceId = text(job.payload, 'device_id');
    if (!deviceId) throw new Error('eta.submit needs a POS');

    for (const late of await store.claimDeadlineAlerts(deviceId, deadlineHours, now())) {
      alert(log, 'deadline', {
        orgId: late.organization_id,
        fiscalId: late.fiscal_id,
        receipt: late.internal_id,
        issuedAt: late.issued_at,
      });
    }

    let sent = 0;
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const rows = await store.claimForSubmit(deviceId, batchSize, leaseSeconds);
      if (rows.length === 0) break;

      const login = sessionOf(deviceId, await store.credentials(orgId, deviceId));
      if ('problem' in login) {
        const err = new EtaError('auth', login.problem);
        for (const row of rows) await failed(row, err, log);
        break;
      }
      const { session } = login;

      // The ETA is down or refuses the login: every later call would fail the same way.
      let down: EtaError | undefined;
      const toSend: SubmitRow[] = [];
      for (const row of rows) {
        if (down) {
          await failed(row, down, log);
          continue;
        }
        // A receipt made for one ETA system is never sent to the other.
        if (row.environment !== session.environment) {
          await failed(
            row,
            new EtaError('rejected', `the receipt belongs to ${row.environment}`),
            log,
          );
          continue;
        }
        if (!row.was_sent) {
          toSend.push(row);
          continue;
        }
        try {
          const hit = await client.lookup(session, row.uuid);
          if (hit) await found(row, hit, log);
          else toSend.push(row);
        } catch (err) {
          if (!(err instanceof EtaError)) throw err;
          // A lookup that fails says nothing about the receipt: it waits, whatever the answer.
          down =
            err.kind === 'rejected'
              ? new EtaError('unknown', `lookup refused: ${err.message}`)
              : err;
          await failed(row, down, log);
        }
        await sleep(lookupGapMs);
      }

      for (const batch of batchesBySize(toSend, maxBatchBytes)) {
        if (down) {
          for (const row of batch) await failed(row, down, log);
          continue;
        }
        try {
          const receiptsJson = batch.map((row) => row.receipt_json);
          const result = await client.submit(
            session,
            receiptsJson,
            await signer.sign(receiptsJson),
          );
          const accepted = new Map(result.accepted.map((doc) => [doc.uuid, doc]));
          const rejected = new Map(
            result.rejected.map((doc) => [doc.uuid ?? doc.receiptNumber, doc]),
          );
          for (const row of batch) {
            const ok = accepted.get(row.uuid);
            const refused = rejected.get(row.uuid) ?? rejected.get(row.internal_id);
            if (ok) {
              await store.mark(row.fiscal_id, 'submitted', {
                eta_long_id: ok.longId,
                eta_submission_uuid: result.submissionUuid,
                poll_in_seconds: delayAt(pollDelays, 0),
              });
              sent += 1;
            } else if (refused) {
              await failed(row, new EtaError('rejected', refused.error), log);
            } else {
              // The answer names neither: treated as unknown, so it is looked up before a resend.
              await failed(
                row,
                new EtaError('unknown', 'the submit answer did not name the receipt'),
                log,
              );
            }
          }
        } catch (err) {
          if (!(err instanceof EtaError)) throw err;
          for (const row of batch) await failed(row, err, log);
          if (err.kind !== 'rejected') down = err;
        }
      }
      if (down || rows.length < batchSize) break;
    }
    log.info({ deviceId, sent }, 'eta.submit done');
  };

  const poll: JobHandler = async (job, log) => {
    const orgId = orgOf(job);
    const submissionUuid = text(job.payload, 'submission_uuid');
    const deviceId = text(job.payload, 'device_id');
    const count = job.payload['n'];
    const n = typeof count === 'number' ? count : 0;
    if (!submissionUuid || !deviceId) throw new Error('eta.poll needs a submission and a POS');

    const rows = await store.loadSubmitted(orgId, submissionUuid);
    if (rows.length === 0) return; // every receipt of it has its answer

    let waiting = rows.length;
    const login = sessionOf(deviceId, await store.credentials(orgId, deviceId));
    if ('session' in login) {
      try {
        const details = await client.submissionDetails(login.session, submissionUuid);
        const byUuid = new Map(details.receipts.map((doc) => [doc.uuid, doc]));
        for (const row of rows) {
          const doc = byUuid.get(row.uuid);
          if (doc?.status === 'valid') {
            await store.mark(row.fiscal_id, 'accepted', { eta_long_id: doc.longId });
            waiting -= 1;
          } else if (doc?.status === 'invalid' || doc?.status === 'cancelled') {
            const code = doc.status === 'invalid' ? 'ETA_INVALID' : 'ETA_CANCELLED';
            await store.mark(row.fiscal_id, 'rejected', {
              last_error: `${code}: ${doc.error ?? 'no reason given'}`,
              eta_long_id: doc.longId,
            });
            alert(log, doc.status, { orgId, fiscalId: row.fiscal_id, receipt: row.internal_id });
            waiting -= 1;
          }
        }
      } catch (err) {
        if (!(err instanceof EtaError)) throw err;
        log.warn({ submissionUuid, kind: err.kind, status: err.status }, 'eta.poll: no answer yet');
      }
    } else {
      log.warn({ submissionUuid, problem: login.problem }, 'eta.poll: the POS cannot log in');
    }

    if (waiting === 0) return;
    if (n + 1 >= maxPolls) {
      alert(log, 'poll_timeout', { orgId, submissionUuid, waiting });
      return;
    }
    await store.enqueue(
      orgId,
      'eta.poll',
      `eta.poll:${submissionUuid}:${n + 1}`,
      { submission_uuid: submissionUuid, device_id: deviceId, n: n + 1 },
      delayAt(pollDelays, n + 1),
    );
  };

  return { 'eta.prepare': prepare, 'eta.submit': submit, 'eta.poll': poll };
}
