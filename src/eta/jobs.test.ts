import type { FiscalStatus } from '@ziadkhaled-wb/contracts';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Job } from '../jobs/types';
import { createLogger } from '../utils/logger';
import { captureProblem } from '../utils/monitoring';
import {
  EtaError,
  type EtaApi,
  type LookupResult,
  type SubmissionDetails,
  type SubmitResult,
} from './client';
import type { EtaHostMap } from './config';
import { batchesBySize, etaJobHandlers, ETA_RETRY_DELAYS_SECONDS } from './jobs';
import { prepareDevice } from './prepare';
import type {
  CredentialsRow,
  DeadlineRow,
  EtaJobType,
  EtaStore,
  MarkFields,
  PendingRow,
  SubmitRow,
} from './store';

vi.mock('../utils/monitoring', async (original) => ({
  ...(await original<typeof import('../utils/monitoring')>()),
  captureProblem: vi.fn(),
}));

const ORG = '11111111-1111-4111-8111-111111111111';
const DEVICE = '22222222-2222-4222-8222-222222222222';
const BRANCH = '33333333-3333-4333-8333-333333333333';
const NATIONAL_ID = '29901011234567';
const HOSTS: EtaHostMap = {
  preprod: { idUrl: 'https://id.pre', apiUrl: 'https://api.pre', portalUrl: 'https://portal.pre' },
  prod: { idUrl: 'https://id.prod', apiUrl: 'https://api.prod', portalUrl: 'https://portal.prod' },
};

interface FakeRow {
  id: string;
  deviceId: string | null;
  environment: 'preprod' | 'prod';
  number: string;
  issuedAt: string;
  status: FiscalStatus;
  uuid: string | null;
  previousUuid: string | null;
  receiptJson: string | null;
  qr: string | null;
  attempts: number;
  /** Seconds on the fake clock; null = due now. */
  nextRetryAt: number | null;
  lastError: string | null;
  sent: boolean;
  submissionUuid: string | null;
  longId: string | null;
  deadlineAlerted: boolean;
  source: Partial<PendingRow>;
}

interface QueuedJob {
  type: EtaJobType;
  key: string;
  payload: Record<string, unknown>;
  delay: number;
}

/** The T02 database functions, in memory, with the same rules as the SQL. */
class FakeStore implements EtaStore {
  rows: FakeRow[] = [];
  jobs: QueuedJob[] = [];
  lastUuid = '';
  /** The fake clock, in seconds. */
  clock = 0;
  credentialsRow: CredentialsRow | null = {
    environment: 'preprod',
    client_id: 'client',
    client_secret: 'secret',
    pos_serial: 'POS-001',
    pos_os_version: 'os',
    pos_model_framework: '1',
    preshared_key: 'key',
    device_status: 'active',
    device_active: true,
  };
  /** Runs right before a receipt is stored: another worker gets in first. */
  beforeStore: (() => void) | undefined;

  sale(n: number, over: Partial<FakeRow> = {}, source: Partial<PendingRow> = {}): FakeRow {
    const row: FakeRow = {
      id: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`,
      deviceId: DEVICE,
      environment: 'preprod',
      number: `SL-${String(n).padStart(4, '0')}`,
      issuedAt: `2026-10-12T09:${String(n).padStart(2, '0')}:00Z`,
      status: 'pending',
      uuid: null,
      previousUuid: null,
      receiptJson: null,
      qr: null,
      attempts: 0,
      nextRetryAt: null,
      lastError: null,
      sent: false,
      submissionUuid: null,
      longId: null,
      deadlineAlerted: false,
      source,
      ...over,
    };
    this.rows.push(row);
    return row;
  }

  private get(id: string): FakeRow {
    const row = this.rows.find((r) => r.id === id);
    if (!row) throw new Error('FISCAL_NOT_FOUND');
    return row;
  }

  private pendingRow(row: FakeRow): PendingRow {
    return {
      fiscal_id: row.id,
      organization_id: ORG,
      environment: row.environment,
      sale: {
        id: row.id,
        number: row.number,
        issued_at: row.issuedAt,
        prices_include_vat: true,
        total: '1140.00',
      },
      lines: [
        {
          line_no: 1,
          quantity: 1,
          unit_price: '1140.00',
          discount_amount: '0.00',
          tax_rate: '14.00',
          tax_amount: '140.00',
          line_total: '1140.00',
          sku: 'TV-55',
          name: 'TV 55',
          eta_item_code: 'EG-1',
          eta_item_type: 'EGS',
          eta_tax_type: 'T1',
          eta_subtype: 'V009',
        },
      ],
      payments: [{ method: 'cash', amount: '1140.00' }],
      customer: null,
      seller: {
        rin: '674859545',
        name: 'Al Nour',
        activity_code: '4753',
        branch_code: '0',
        governorate: 'Cairo',
        city: 'Nasr City',
        street: '16 Abbas El Akkad',
        building_number: '14',
      },
      device: row.deviceId
        ? { id: row.deviceId, serial: 'POS-001', status: 'active', is_active: true }
        : null,
      ...row.source,
    };
  }

  loadPending(deviceId: string | null, _branchId: string | null, limit: number) {
    const rows = this.rows
      .filter((r) => r.status === 'pending' && r.uuid === null && r.deviceId === deviceId)
      .sort((a, b) => a.issuedAt.localeCompare(b.issuedAt) || a.number.localeCompare(b.number))
      .slice(0, limit)
      .map((r) => this.pendingRow(r));
    return Promise.resolve({ lastUuid: deviceId ? this.lastUuid : '', rows });
  }

  credentials() {
    return Promise.resolve(this.credentialsRow);
  }

  storePrepared(
    fiscalId: string,
    uuid: string,
    previousUuid: string,
    receiptJson: string,
    qr: string,
  ) {
    this.beforeStore?.();
    const row = this.get(fiscalId);
    if (row.status !== 'pending' || row.uuid !== null) return Promise.resolve('already' as const);
    if (this.lastUuid !== previousUuid) return Promise.resolve('moved' as const);
    this.lastUuid = uuid;
    Object.assign(row, { uuid, previousUuid, receiptJson, qr, nextRetryAt: null, lastError: null });
    this.jobs.push({
      type: 'eta.submit',
      key: `eta.submit:${row.deviceId}`,
      payload: {},
      delay: 0,
    });
    return Promise.resolve('stored' as const);
  }

  block(fiscalId: string, code: string, message: string) {
    const row = this.get(fiscalId);
    if (row.status !== 'pending' || row.uuid !== null) return Promise.resolve(false);
    Object.assign(row, { status: 'failed', lastError: `${code}: ${message}`, nextRetryAt: null });
    row.attempts += 1;
    return Promise.resolve(true);
  }

  claimForSubmit(deviceId: string, limit: number, leaseSeconds: number) {
    const due = this.rows
      .filter(
        (r) =>
          r.deviceId === deviceId &&
          r.status === 'pending' &&
          r.uuid !== null &&
          (r.nextRetryAt === null || r.nextRetryAt <= this.clock),
      )
      .sort((a, b) => a.issuedAt.localeCompare(b.issuedAt))
      .slice(0, limit);
    const out: SubmitRow[] = due.map((r) => ({
      fiscal_id: r.id,
      organization_id: ORG,
      environment: r.environment,
      internal_id: r.number,
      uuid: r.uuid ?? '',
      attempts: r.attempts,
      receipt_json: r.receiptJson ?? '',
      was_sent: r.sent,
    }));
    for (const r of due) {
      r.nextRetryAt = this.clock + leaseSeconds;
      r.sent = true;
    }
    return Promise.resolve(out);
  }

  mark(fiscalId: string, status: FiscalStatus, fields: MarkFields = {}) {
    const row = this.get(fiscalId);
    if (row.status === 'accepted' || row.status === 'cancelled') return Promise.resolve(row.status);
    if (row.status === 'rejected' && status === 'rejected') return Promise.resolve(row.status);
    const allowed =
      (status === 'pending' && row.status === 'pending') ||
      (status === 'submitted' && (row.status === 'pending' || row.status === 'submitted')) ||
      (status === 'accepted' && row.status === 'submitted') ||
      (status === 'rejected' && (row.status === 'pending' || row.status === 'submitted'));
    if (!allowed || row.uuid === null)
      throw new Error(`FISCAL_BAD_TRANSITION ${row.status} ${status}`);
    if (fields.last_error) row.attempts += 1;
    row.lastError =
      status === 'submitted' || status === 'accepted' ? null : (fields.last_error ?? row.lastError);
    row.nextRetryAt = status === 'pending' ? this.clock + (fields.retry_in_seconds ?? 0) : null;
    row.longId = fields.eta_long_id ?? row.longId;
    row.submissionUuid = fields.eta_submission_uuid ?? row.submissionUuid;
    row.status = status;
    if (status === 'pending') {
      this.jobs.push({
        type: 'eta.submit',
        key: `eta.submit:${row.deviceId}`,
        payload: {},
        delay: fields.retry_in_seconds ?? 0,
      });
    } else if (status === 'submitted' && row.submissionUuid) {
      this.jobs.push({
        type: 'eta.poll',
        key: `eta.poll:${row.submissionUuid}:0`,
        payload: { submission_uuid: row.submissionUuid, device_id: row.deviceId, n: 0 },
        delay: fields.poll_in_seconds ?? 30,
      });
    }
    return Promise.resolve(row.status);
  }

  loadSubmitted(_orgId: string, submissionUuid: string) {
    return Promise.resolve(
      this.rows
        .filter((r) => r.status === 'submitted' && r.submissionUuid === submissionUuid)
        .map((r) => ({ fiscal_id: r.id, uuid: r.uuid ?? '', internal_id: r.number })),
    );
  }

  claimDeadlineAlerts(deviceId: string, hours: number, now: Date) {
    const late = this.rows.filter(
      (r) =>
        r.deviceId === deviceId &&
        r.status === 'pending' &&
        !r.deadlineAlerted &&
        Date.parse(r.issuedAt) < now.getTime() - hours * 3_600_000,
    );
    for (const r of late) r.deadlineAlerted = true;
    return Promise.resolve(
      late.map((r): DeadlineRow => ({
        fiscal_id: r.id,
        organization_id: ORG,
        internal_id: r.number,
        issued_at: r.issuedAt,
      })),
    );
  }

  enqueue(
    _orgId: string,
    type: EtaJobType,
    key: string,
    payload: Record<string, unknown>,
    delay: number,
  ) {
    this.jobs.push({ type, key, payload, delay });
    return Promise.resolve();
  }

  loadForCorrection() {
    return Promise.reject(new Error('not used by the T02 job tests'));
  }

  storeCorrection() {
    return Promise.reject(new Error('not used by the T02 job tests'));
  }

  noteCorrection() {
    return Promise.reject(new Error('not used by the T02 job tests'));
  }

  saleStatus() {
    return Promise.resolve(null);
  }
}

/** A scripted ETA: every call is recorded; a reply is a value or an error to throw. */
function fakeEta() {
  const sent: string[][] = [];
  const lookups: string[] = [];
  const polls: string[] = [];
  const replies = {
    submit: [] as (SubmitResult | EtaError)[],
    lookup: [] as (LookupResult | null | EtaError)[],
    details: [] as (SubmissionDetails | EtaError)[],
  };
  let submissions = 0;
  const next = <T>(queue: (T | EtaError)[], fallback: () => T): T => {
    const reply = queue.shift();
    if (reply instanceof EtaError) throw reply;
    return reply === undefined ? fallback() : reply;
  };
  const client: EtaApi = {
    token: () => Promise.resolve('token'),
    submit: (_session, receiptsJson) => {
      sent.push([...receiptsJson]);
      return Promise.resolve().then(() =>
        next(replies.submit, () => {
          submissions += 1;
          return {
            submissionUuid: `SUB${submissions}`,
            accepted: receiptsJson.map((json) => ({
              uuid: /"uuid":"([0-9a-f]{64})"/.exec(json)?.[1] ?? '',
              longId: 'LONG',
            })),
            rejected: [],
          };
        }),
      );
    },
    lookup: (_session, uuid) => {
      lookups.push(uuid);
      return Promise.resolve().then(() => next(replies.lookup, () => null));
    },
    submissionDetails: (_session, submissionUuid) => {
      polls.push(submissionUuid);
      return Promise.resolve().then(() =>
        next(replies.details, (): SubmissionDetails => ({ status: 'inprogress', receipts: [] })),
      );
    },
  };
  return { client, sent, lookups, polls, replies };
}

function setup(options: Partial<Parameters<typeof etaJobHandlers>[0]> = {}) {
  const store = new FakeStore();
  const eta = fakeEta();
  const logs: string[] = [];
  const logger = createLogger({ level: 'trace', stream: { write: (line) => logs.push(line) } });
  const handlers = etaJobHandlers({
    store,
    client: eta.client,
    hosts: HOSTS,
    logger,
    lookupGapMs: 0,
    // A fixed clock, an hour after the fixtures' sales: the tests never depend on today's date.
    now: () => new Date('2026-10-12T10:30:00Z'),
    ...options,
  });
  const job = (type: EtaJobType, payload: Record<string, unknown>): Job => ({
    id: 'job-1',
    organizationId: ORG,
    type,
    payload,
    attempt: 1,
    maxAttempts: 5,
  });
  return {
    store,
    eta,
    logs,
    logger,
    prepare: () =>
      handlers['eta.prepare'](job('eta.prepare', { device_id: DEVICE, branch_id: BRANCH }), logger),
    submit: () => handlers['eta.submit'](job('eta.submit', { device_id: DEVICE }), logger),
    poll: (submissionUuid: string, n = 0) =>
      handlers['eta.poll'](
        job('eta.poll', { submission_uuid: submissionUuid, device_id: DEVICE, n }),
        logger,
      ),
  };
}

const alerts = () =>
  vi
    .mocked(captureProblem)
    .mock.calls.map(([, tags]) => (tags as Record<string, unknown>)['reason']);

beforeEach(() => {
  vi.mocked(captureProblem).mockClear();
});

describe('eta.prepare', () => {
  it('builds the pending receipts in issue order, each chained to the one before', async () => {
    const t = setup();
    const third = t.store.sale(3);
    const first = t.store.sale(1);
    const second = t.store.sale(2);
    await t.prepare();

    expect(first.uuid).toMatch(/^[0-9a-f]{64}$/);
    expect(first.previousUuid).toBe('');
    expect(second.previousUuid).toBe(first.uuid);
    expect(third.previousUuid).toBe(second.uuid);
    expect(t.store.lastUuid).toBe(third.uuid);
    expect(JSON.parse(first.receiptJson ?? '{}')).toMatchObject({
      header: { uuid: first.uuid, previousUUID: '', receiptNumber: 'SL-0001' },
    });
    expect(first.qr).toBe(
      `https://portal.pre/receipts/search/${first.uuid}/share/2026-10-12T09:01:00Z#Total:1140.00,IssuerRIN:674859545`,
    );
    // Each stored receipt queues the POS's submit job (the database does it in the same statement).
    expect(t.store.jobs.filter((j) => j.type === 'eta.submit')).toHaveLength(3);
  });

  it('S05: a return receipt joins the chain with the sale receipt as its referenceUUID', async () => {
    const t = setup();
    const sale = t.store.sale(1);
    await t.prepare();
    const ret = t.store.sale(
      2,
      { number: 'RT-0001' },
      { kind: 'return', original: { uuid: sale.uuid!, issued_at: '2026-10-12T09:01:00Z' } },
    );
    await t.prepare();
    expect(ret.previousUuid).toBe(sale.uuid);
    expect(JSON.parse(ret.receiptJson ?? '{}')).toMatchObject({
      header: { receiptNumber: 'RT-0001', previousUUID: sale.uuid, referenceUUID: sale.uuid },
      documentType: { receiptType: 'r' },
    });
  });

  it('S05: a return more than 540 days after its sale receipt is blocked, not sent', async () => {
    const t = setup();
    const ret = t.store.sale(
      1,
      { number: 'RT-0002' },
      { kind: 'return', original: { uuid: 'd'.repeat(64), issued_at: '2024-01-01T09:00:00Z' } },
    );
    await t.prepare();
    expect(ret.status).toBe('failed');
    expect(ret.lastError).toMatch(/^BLOCKED:RETURN_TOO_LATE/);
  });

  it('goes on from the last UUID of the POS', async () => {
    const t = setup();
    t.store.lastUuid = 'c'.repeat(64);
    const row = t.store.sale(1);
    await t.prepare();
    expect(row.previousUuid).toBe('c'.repeat(64));
  });

  it('a blocked receipt alerts once and does not stop the chain', async () => {
    const t = setup();
    const first = t.store.sale(1);
    const blocked = t.store.sale(2, {}, { lines: [] });
    blocked.source = {
      lines: [
        {
          line_no: 1,
          quantity: 1,
          unit_price: '1140.00',
          discount_amount: '0.00',
          tax_rate: '14.00',
          tax_amount: '140.00',
          line_total: '1140.00',
          sku: 'SOFA-3',
          name: 'Sofa',
          eta_item_code: null,
          eta_item_type: null,
          eta_tax_type: 'T1',
          eta_subtype: 'V009',
        },
      ],
    };
    const third = t.store.sale(3);
    await t.prepare();

    expect(blocked.status).toBe('failed');
    expect(blocked.lastError).toMatch(/^BLOCKED:ITEM_CODE: .*SOFA-3/);
    expect(blocked.nextRetryAt).toBeNull();
    expect(blocked.uuid).toBeNull();
    expect(third.previousUuid).toBe(first.uuid);
    expect(alerts()).toEqual(['BLOCKED:ITEM_CODE']);
    expect(vi.mocked(captureProblem).mock.calls[0]?.[1]).toMatchObject({ problem: 'eta.failed' });

    await t.prepare(); // nothing left: no second alert
    expect(alerts()).toHaveLength(1);
  });

  it('a sale without a POS is blocked with NO_DEVICE', async () => {
    const t = setup();
    const row = t.store.sale(1, { deviceId: null });
    await prepareDevice(
      { store: t.store, hosts: HOSTS, logger: t.logger },
      { deviceId: null, branchId: BRANCH },
    );
    expect(row.status).toBe('failed');
    expect(row.lastError).toMatch(/^BLOCKED:NO_DEVICE/);
  });

  it('CHAIN_MOVED: reads the chain again and builds the receipt again', async () => {
    const t = setup();
    const row = t.store.sale(1);
    const moved = 'd'.repeat(64);
    let hits = 0;
    t.store.beforeStore = () => {
      hits += 1;
      if (hits === 1) t.store.lastUuid = moved; // another worker stored a receipt in between
    };
    await t.prepare();
    expect(hits).toBe(2);
    expect(row.previousUuid).toBe(moved);
    expect(JSON.parse(row.receiptJson ?? '{}')).toMatchObject({ header: { previousUUID: moved } });
    expect(t.store.lastUuid).toBe(row.uuid);
  });

  it('gives up after the chain moved 5 times in a row', async () => {
    const t = setup();
    const row = t.store.sale(1);
    let n = 0;
    t.store.beforeStore = () => {
      n += 1;
      t.store.lastUuid = String(n).padStart(64, 'e');
    };
    await expect(t.prepare()).rejects.toThrow(/moved 6 times/);
    expect(n).toBe(6); // the first try and 5 more
    expect(row.uuid).toBeNull();
  });

  it('ALREADY_PREPARED: keeps the UUID another worker stored and goes on with the rest', async () => {
    const t = setup();
    const first = t.store.sale(1);
    const second = t.store.sale(2);
    const theirs = 'f'.repeat(64);
    let once = true;
    t.store.beforeStore = () => {
      if (!once) return;
      once = false;
      Object.assign(first, { uuid: theirs, previousUuid: '' });
      t.store.lastUuid = theirs;
    };
    await t.prepare();
    expect(first.uuid).toBe(theirs);
    expect(second.previousUuid).toBe(theirs);
  });

  it('stops at its deadline and says it did not finish', async () => {
    const t = setup();
    const row = t.store.sale(1);
    const result = await prepareDevice(
      { store: t.store, hosts: HOSTS, logger: t.logger },
      { deviceId: DEVICE, branchId: BRANCH },
      { deadline: 1000, now: () => 1000 },
    );
    expect(result).toEqual({ prepared: 0, blocked: 0, finished: false });
    expect(row.uuid).toBeNull();
  });

  it('never logs the buyer national ID, blocked or built', async () => {
    const t = setup();
    const big = {
      sale: {
        id: 'x',
        number: 'SL-0001',
        issued_at: '2026-10-12T09:01:00Z',
        prices_include_vat: true,
        total: '150000.00',
      },
      lines: [
        {
          line_no: 1,
          quantity: 1,
          unit_price: '150000.00',
          discount_amount: '0.00',
          tax_rate: '14.00',
          tax_amount: '18421.05',
          line_total: '150000.00',
          sku: 'BED',
          name: 'Bed',
          eta_item_code: 'EG-2',
          eta_item_type: 'EGS',
          eta_tax_type: 'T1',
          eta_subtype: 'V009',
        },
      ],
      payments: [{ method: 'cash', amount: '150000.00' }],
    };
    const built = t.store.sale(
      1,
      {},
      {
        ...big,
        customer: {
          name: 'Mona',
          national_id: NATIONAL_ID,
          is_business: false,
          tax_registration_no: null,
        },
      },
    );
    const blocked = t.store.sale(
      2,
      {},
      {
        ...big,
        customer: {
          name: '',
          national_id: NATIONAL_ID,
          is_business: false,
          tax_registration_no: null,
        },
      },
    );
    await t.prepare();
    expect(built.receiptJson).toContain(NATIONAL_ID); // it is sent to the ETA...
    expect(blocked.lastError).toMatch(/^BLOCKED:BUYER_ID/);
    expect(t.logs.join('\n')).not.toContain(NATIONAL_ID); // ...and never logged
    expect(JSON.stringify(vi.mocked(captureProblem).mock.calls)).not.toContain(NATIONAL_ID);
    expect(blocked.lastError).not.toContain(NATIONAL_ID);
  });
});

describe('eta.submit', () => {
  async function prepared(t: ReturnType<typeof setup>, count: number) {
    const rows = Array.from({ length: count }, (_, i) => t.store.sale(i + 1));
    await t.prepare();
    t.store.jobs = [];
    return rows;
  }

  it('sends the prepared receipts in issue order and moves them to submitted', async () => {
    const t = setup();
    const rows = await prepared(t, 3);
    await t.submit();

    expect(t.eta.sent).toHaveLength(1);
    expect(t.eta.sent[0]).toEqual(rows.map((r) => r.receiptJson));
    expect(t.eta.lookups).toEqual([]);
    for (const row of rows) {
      expect(row).toMatchObject({
        status: 'submitted',
        submissionUuid: 'SUB1',
        longId: 'LONG',
        lastError: null,
      });
    }
    expect(t.store.jobs[0]).toEqual({
      type: 'eta.poll',
      key: 'eta.poll:SUB1:0',
      payload: { submission_uuid: 'SUB1', device_id: DEVICE, n: 0 },
      delay: 30,
    });
  });

  it('an unknown outcome is looked up by UUID before any resend: found means submitted, sent once', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    t.eta.replies.submit.push(
      new EtaError('unknown', 'The ETA could not be reached (TimeoutError)'),
    );
    await t.submit();
    expect(row).toMatchObject({ status: 'pending', attempts: 1, nextRetryAt: 60, sent: true });
    expect(row?.lastError).toMatch(/^ETA_UNREACHABLE: /);

    // Not due yet: nothing is sent or looked up.
    await t.submit();
    expect(t.eta.sent).toHaveLength(1);
    expect(t.eta.lookups).toHaveLength(0);

    t.store.clock = 60;
    t.eta.replies.lookup.push({ submissionUuid: 'SUB-LOST', longId: 'LONG9', status: 'other' });
    await t.submit();
    expect(t.eta.lookups).toEqual([row?.uuid]);
    expect(t.eta.sent).toHaveLength(1); // never sent a second time
    expect(row).toMatchObject({ status: 'submitted', submissionUuid: 'SUB-LOST', longId: 'LONG9' });
    expect(t.store.jobs.at(-1)).toMatchObject({ type: 'eta.poll', key: 'eta.poll:SUB-LOST:0' });
  });

  it('a receipt the ETA does not have is sent again after the lookup', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    t.eta.replies.submit.push(new EtaError('unknown', 'HTTP 502', { status: 502 }));
    await t.submit();
    t.store.clock = 60;
    await t.submit(); // lookup answers null (not there), then the send works
    expect(t.eta.lookups).toHaveLength(1);
    expect(t.eta.sent).toHaveLength(2);
    expect(row?.status).toBe('submitted');
  });

  it('422 DuplicateSubmission: waits for Retry-After, then looks the receipt up', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    t.eta.replies.submit.push(
      new EtaError('duplicate', 'DuplicateSubmission', { status: 422, retryAfterSeconds: 45 }),
    );
    await t.submit();
    expect(row).toMatchObject({ status: 'pending', nextRetryAt: 46 });
    expect(row?.lastError).toMatch(/^ETA_DUPLICATE: /);
    expect(t.store.jobs.at(-1)).toMatchObject({ type: 'eta.submit', delay: 46 });

    t.store.clock = 45;
    await t.submit();
    expect(t.eta.lookups).toHaveLength(0); // still waiting

    t.store.clock = 46;
    t.eta.replies.lookup.push({ submissionUuid: 'SUB7', longId: 'L', status: 'other' });
    await t.submit();
    expect(t.eta.sent).toHaveLength(1);
    expect(row).toMatchObject({ status: 'submitted', submissionUuid: 'SUB7' });
  });

  it('backs off 1 min, 5 min, 15 min, 1 h, then every 2 h', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    const waits: number[] = [];
    for (let i = 0; i < 7; i++) {
      t.eta.replies.lookup.push(new EtaError('unknown', 'down'));
      t.eta.replies.submit.push(new EtaError('unknown', 'down'));
      const before = t.store.clock;
      await t.submit();
      waits.push((row?.nextRetryAt ?? 0) - before);
      t.store.clock = row?.nextRetryAt ?? 0;
    }
    expect(waits).toEqual([60, 300, 900, 3600, 7200, 7200, 7200]);
    expect([...ETA_RETRY_DELAYS_SECONDS]).toEqual([60, 300, 900, 3600, 7200]);
    expect(row?.status).toBe('pending'); // it never stops retrying
    expect(row?.attempts).toBe(7);
  });

  it('a receipt refused in the submit answer is rejected with the reason, the others go on', async () => {
    const t = setup();
    const [good, bad] = await prepared(t, 2);
    t.eta.replies.submit.push({
      submissionUuid: 'SUB1',
      accepted: [{ uuid: good?.uuid ?? '', longId: 'LONG' }],
      rejected: [
        {
          uuid: bad?.uuid ?? '',
          receiptNumber: bad?.number ?? '',
          error: 'CF313 date out of range',
        },
      ],
    });
    await t.submit();
    expect(good?.status).toBe('submitted');
    expect(bad).toMatchObject({
      status: 'rejected',
      lastError: 'ETA_REJECTED: CF313 date out of range',
    });
    expect(alerts()).toEqual(['rejected']);
    await t.submit(); // a rejected receipt is not sent again by itself
    expect(t.eta.sent).toHaveLength(1);
  });

  it('a submission the ETA refuses as a whole (400) rejects its receipts', async () => {
    const t = setup();
    const rows = await prepared(t, 2);
    t.eta.replies.submit.push(new EtaError('rejected', 'BadStructure wrong body', { status: 400 }));
    await t.submit();
    for (const row of rows) {
      expect(row).toMatchObject({
        status: 'rejected',
        lastError: 'ETA_REJECTED: BadStructure wrong body',
      });
    }
  });

  it('a receipt the answer does not name is treated as unknown', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    t.eta.replies.submit.push({ submissionUuid: 'SUB1', accepted: [], rejected: [] });
    await t.submit();
    expect(row).toMatchObject({ status: 'pending', attempts: 1, sent: true });
  });

  it('a POS that cannot log in keeps its receipts pending and alerts once', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    t.store.credentialsRow = { ...t.store.credentialsRow!, preshared_key: null };
    await t.submit();
    expect(row).toMatchObject({ status: 'pending', attempts: 1, nextRetryAt: 60 });
    expect(row?.lastError).toBe('ETA_AUTH: the POS registration is incomplete');
    expect(t.eta.sent).toHaveLength(0);
    expect(alerts()).toEqual(['auth']);

    t.store.clock = 60;
    await t.submit();
    expect(alerts()).toEqual(['auth']); // the second failure doesn't alert again
    expect(row?.nextRetryAt).toBe(360);

    for (const broken of [
      { ...t.store.credentialsRow, device_status: 'revoked' },
      { ...t.store.credentialsRow, client_secret: null },
      null,
    ]) {
      t.store.credentialsRow = broken;
      t.store.clock = row?.nextRetryAt ?? 0;
      await t.submit();
    }
    expect(t.eta.sent).toHaveLength(0);
  });

  it('never sends a receipt made for the other ETA system', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    if (row) row.environment = 'prod'; // the shop's credentials are preprod
    await t.submit();
    expect(t.eta.sent).toHaveLength(0);
    expect(row).toMatchObject({
      status: 'rejected',
      lastError: 'ETA_REJECTED: the receipt belongs to prod',
    });
  });

  it('once the ETA is down, makes no further call in that run', async () => {
    const t = setup();
    const rows = await prepared(t, 3);
    for (const row of rows) row.sent = true; // all three need a lookup
    t.eta.replies.lookup.push(new EtaError('unknown', 'down'));
    await t.submit();
    expect(t.eta.lookups).toHaveLength(1);
    expect(t.eta.sent).toHaveLength(0);
    for (const row of rows) expect(row).toMatchObject({ status: 'pending', attempts: 1 });
  });

  it('a lookup the ETA refuses says nothing about the receipt: it waits', async () => {
    const t = setup();
    const [row] = await prepared(t, 1);
    if (row) row.sent = true;
    t.eta.replies.lookup.push(new EtaError('rejected', 'Forbidden', { status: 403 }));
    await t.submit();
    expect(row?.status).toBe('pending');
    expect(row?.lastError).toMatch(/^ETA_UNREACHABLE: lookup refused/);
  });

  it('alerts once for a receipt still pending 20 hours after its sale, and keeps trying', async () => {
    const now = new Date('2026-10-13T06:00:00Z'); // the sale of 09:01 is 20 h 59 min old
    const t = setup({ now: () => now });
    const [late] = await prepared(t, 1);
    t.eta.replies.submit.push(new EtaError('unknown', 'down'));
    await t.submit();
    expect(alerts()).toEqual(['deadline']);
    expect(late?.status).toBe('pending');

    t.store.clock = 60;
    t.eta.replies.lookup.push(new EtaError('unknown', 'down'));
    await t.submit();
    await t.submit();
    expect(alerts()).toEqual(['deadline']); // exactly once
  });

  it('a receipt younger than 20 hours does not alert', async () => {
    const t = setup({ now: () => new Date('2026-10-13T05:00:00Z') });
    await prepared(t, 1);
    await t.submit();
    expect(alerts()).toEqual([]);
  });

  it('splits a submission that would pass the byte limit', () => {
    const row = (n: number, bytes: number): SubmitRow => ({
      fiscal_id: String(n),
      organization_id: ORG,
      environment: 'preprod',
      internal_id: String(n),
      uuid: String(n),
      attempts: 0,
      receipt_json: 'x'.repeat(bytes),
      was_sent: false,
    });
    const batches = batchesBySize(
      [row(1, 40), row(2, 40), row(3, 40), row(4, 500), row(5, 10)],
      100,
    );
    expect(batches.map((b) => b.map((r) => r.internal_id))).toEqual([
      ['1', '2'],
      ['3'],
      ['4'],
      ['5'],
    ]);
    expect(batchesBySize([], 100)).toEqual([]);
    // Arabic text counts in bytes, not characters.
    expect(
      batchesBySize([{ ...row(1, 0), receipt_json: 'م'.repeat(40) }, row(2, 30)], 100),
    ).toHaveLength(2);
  });

  it('sends more than one batch in a run', async () => {
    const t = setup({ batchSize: 2 });
    await prepared(t, 5);
    await t.submit();
    expect(t.eta.sent.map((batch) => batch.length)).toEqual([2, 2, 1]);
  });
});

describe('eta.poll', () => {
  async function submitted(t: ReturnType<typeof setup>, count: number) {
    const rows = Array.from({ length: count }, (_, i) => t.store.sale(i + 1));
    await t.prepare();
    await t.submit();
    t.store.jobs = [];
    return rows;
  }

  it('Valid becomes accepted, Invalid becomes rejected with the reason', async () => {
    const t = setup();
    const [ok, bad] = await submitted(t, 2);
    t.eta.replies.details.push({
      status: 'invalid',
      receipts: [
        { uuid: ok?.uuid ?? '', longId: 'LONG-OK', status: 'valid', error: null },
        {
          uuid: bad?.uuid ?? '',
          longId: 'LONG-BAD',
          status: 'invalid',
          error: 'CV307 bad item code',
        },
      ],
    });
    await t.poll('SUB1');
    expect(ok).toMatchObject({ status: 'accepted', longId: 'LONG-OK', lastError: null });
    expect(bad).toMatchObject({
      status: 'rejected',
      lastError: 'ETA_INVALID: CV307 bad item code',
    });
    expect(alerts()).toEqual(['invalid']);
    expect(t.store.jobs).toEqual([]); // every receipt has its answer: no further poll

    await t.poll('SUB1'); // a repeated poll finds nothing left and calls nobody
    expect(t.eta.polls).toHaveLength(1);
  });

  it('while the ETA is still validating, polls again after 2 min, 10 min, then every 30 min', async () => {
    const t = setup();
    await submitted(t, 1);
    for (const n of [0, 1, 2, 3, 9]) await t.poll('SUB1', n);
    expect(t.store.jobs.map((j) => [j.key, j.delay])).toEqual([
      ['eta.poll:SUB1:1', 120],
      ['eta.poll:SUB1:2', 600],
      ['eta.poll:SUB1:3', 1800],
      ['eta.poll:SUB1:4', 1800],
      ['eta.poll:SUB1:10', 1800],
    ]);
    expect(t.store.jobs[0]?.payload).toEqual({ submission_uuid: 'SUB1', device_id: DEVICE, n: 1 });
  });

  it('a poll that cannot reach the ETA is tried again, the receipts stay submitted', async () => {
    const t = setup();
    const [row] = await submitted(t, 1);
    t.eta.replies.details.push(new EtaError('unknown', 'down'));
    await t.poll('SUB1');
    expect(row?.status).toBe('submitted');
    expect(t.store.jobs.at(-1)).toMatchObject({ key: 'eta.poll:SUB1:1' });
  });

  it('gives up with an alert after the last poll', async () => {
    const t = setup({ maxPolls: 3 });
    const [row] = await submitted(t, 1);
    await t.poll('SUB1', 2);
    expect(t.store.jobs).toEqual([]);
    expect(alerts()).toEqual(['poll_timeout']);
    expect(row?.status).toBe('submitted');
  });

  it('a job without a shop, a POS or a submission fails loudly', async () => {
    const t = setup();
    const handlers = etaJobHandlers({
      store: t.store,
      client: t.eta.client,
      hosts: HOSTS,
      logger: t.logger,
    });
    const base = { id: 'j', type: 'eta.submit', attempt: 1, maxAttempts: 5 };
    await expect(
      handlers['eta.submit'](
        { ...base, organizationId: null, payload: { device_id: DEVICE } },
        t.logger,
      ),
    ).rejects.toThrow(/needs a shop/);
    await expect(
      handlers['eta.submit']({ ...base, organizationId: ORG, payload: {} }, t.logger),
    ).rejects.toThrow(/needs a POS/);
    await expect(
      handlers['eta.poll'](
        { ...base, organizationId: ORG, payload: { device_id: DEVICE } },
        t.logger,
      ),
    ).rejects.toThrow(/needs a submission/);
  });
});
