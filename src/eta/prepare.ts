// server/src/eta/prepare.ts
//
// T02 (D67, decisions 2 to 4). Builds the ETA receipts that are pending for one POS, oldest
// first (issue time, then number), each chained to the one before it:
//   - the receipt and its UUID are computed here, from the sale as it was stored;
//   - public.eta_store_prepared stores it only if the POS's last UUID is still the previousUUID
//     it was hashed with (compare-and-set). CHAIN_MOVED: read the chain again and build again,
//     at most 5 times. ALREADY_PREPARED: another worker built it; go on with what is left;
//   - a receipt that can't be built because data is missing is blocked (status 'failed', the
//     reason starting with its code) and alerts once. It doesn't hold up the receipts after it.
// Called by the sale route right after a sale (so the QR code is on the first print) and by the
// eta.prepare job. Safe to run twice and at the same time: a prepared UUID never changes.

import type { Logger } from 'pino';
import { captureProblem } from '../utils/monitoring';
import { buildReceipt, ReceiptBlockedError, type Receipt } from './build-receipt';
import { buildReturnReceipt, ReturnTooLateError } from './build-return';
import type { EtaHostMap } from './config';
import { qrPayload } from '@ziadkhaled-wb/contracts';
import { toJson } from '@ziadkhaled-wb/contracts';
import type { EtaStore, PendingRow } from './store';

/** S05 (D88): a return receipt references its sale's; a sale receipt is built as before. */
function buildRow(row: PendingRow, previous: string): Receipt {
  if (row.kind !== 'return') return buildReceipt(row, previous);
  if (row.original === undefined) throw new RangeError('A return row needs its sale receipt');
  const { sale, original, ...context } = row;
  try {
    return buildReturnReceipt(original, row.lines, {
      ...context,
      return: sale,
      previous_uuid: previous,
    });
  } catch (err) {
    if (err instanceof ReturnTooLateError) {
      throw new ReceiptBlockedError('BLOCKED:RETURN_TOO_LATE', err.message);
    }
    throw err;
  }
}

export interface PrepareDeps {
  store: EtaStore;
  hosts: EtaHostMap;
  logger: Logger;
}

/** A POS, or (deviceId null) the sales a branch made without one. */
export interface PrepareTarget {
  deviceId: string | null;
  branchId: string | null;
}

export interface PrepareOptions {
  /** Stop before the next receipt once this time (ms since the epoch) has passed. */
  deadline?: number;
  now?: () => number;
}

export interface PrepareResult {
  prepared: number;
  blocked: number;
  /** false when the deadline cut the work short: the eta.prepare job does the rest. */
  finished: boolean;
}

const PAGE = 50;
const MAX_CHAIN_MOVES = 5;
/** A guard against a loop that never empties (it would mean a bug, not load). */
const MAX_PASSES = 200;

export async function prepareDevice(
  deps: PrepareDeps,
  target: PrepareTarget,
  options: PrepareOptions = {},
): Promise<PrepareResult> {
  const now = options.now ?? Date.now;
  const result: PrepareResult = { prepared: 0, blocked: 0, finished: true };
  if (target.deviceId === null && target.branchId === null) return result;
  let moves = 0;

  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const { lastUuid, rows } = await deps.store.loadPending(target.deviceId, target.branchId, PAGE);
    if (rows.length === 0) return result;
    let previous = lastUuid;
    let reload = false;

    for (const row of rows) {
      if (options.deadline !== undefined && now() >= options.deadline) {
        result.finished = false;
        return result;
      }
      let receipt;
      try {
        receipt = buildRow(row, previous);
      } catch (err) {
        if (!(err instanceof ReceiptBlockedError)) throw err;
        if (await deps.store.block(row.fiscal_id, err.code, err.message)) {
          deps.logger.error(
            {
              fiscalId: row.fiscal_id,
              orgId: row.organization_id,
              sale: row.sale.number,
              code: err.code,
            },
            'ETA receipt blocked: data is missing',
          );
          captureProblem('eta.failed: a receipt is blocked', {
            problem: 'eta.failed',
            reason: err.code,
            orgId: row.organization_id,
            fiscalId: row.fiscal_id,
            sale: row.sale.number,
          });
        }
        result.blocked += 1;
        continue;
      }

      const outcome = await deps.store.storePrepared(
        row.fiscal_id,
        receipt.header.uuid,
        previous,
        toJson(receipt),
        qrPayload({
          portalUrl: deps.hosts[row.environment].portalUrl,
          uuid: receipt.header.uuid,
          dateTimeIssued: receipt.header.dateTimeIssued,
          totalAmount: receipt.totalAmount.text,
          rin: receipt.seller.rin,
        }),
      );
      if (outcome === 'stored') {
        previous = receipt.header.uuid;
        result.prepared += 1;
        continue;
      }
      if (outcome === 'moved') {
        moves += 1;
        if (moves > MAX_CHAIN_MOVES) {
          throw new Error(`The receipt chain of the POS moved ${moves} times while preparing`);
        }
      }
      reload = true; // moved or already built: what is pending and the chain are read again
      break;
    }
    if (!reload && rows.length < PAGE) return result;
  }
  throw new Error('Preparing receipts did not finish');
}
