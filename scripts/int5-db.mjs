// INT-5 (EC-135): the database side of the installment lifecycle e2e. LOCAL ONLY: everything runs
// as postgres inside the local Supabase database container (`docker exec`, see db-proof-lib.mjs).
//   node scripts/int5-db.mjs backdate <contract id> <days late>
//     Time passes for one contract: its first open installment becomes due <days late> days ago
//     (shop date); its other installments move back by the same number of days. Only the e2e
//     needs this: due dates in the past can't be made through the API.
//   node scripts/int5-db.mjs verify <run.json>
//     The checks of the flow. <run.json> is written by EcoFin-Web/e2e/int5-installment-lifecycle.spec.ts
//     (ids and amounts only). Prints PASS/FAIL per check and exits 1 when one fails.
import { readFileSync } from 'node:fs';
import { psql } from './db-proof-lib.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = (v, what) => {
  if (!UUID.test(String(v))) throw new Error(`${what} is not a uuid: ${v}`);
  return String(v);
};

const [command, ...args] = process.argv.slice(2);

if (command === 'backdate') {
  const contract = uuid(args[0], 'contract id');
  const days = Number(args[1]);
  if (!Number.isInteger(days) || days < 1 || days > 400) throw new Error('days late: 1 to 400');
  const moved = psql(`
    BEGIN;
    SET LOCAL session_replication_role = replica;
    WITH c AS (SELECT id, organization_id, current_version FROM public.contracts WHERE id = '${contract}'),
         first_open AS (
           SELECT sl.due_date FROM public.v_schedule_line_status sl, c
           WHERE sl.contract_id = c.id AND NOT sl.superseded AND sl.remaining > 0
           ORDER BY sl.seq LIMIT 1),
         shift AS (
           SELECT f.due_date - (app.org_today(c.organization_id) - ${days}) AS d FROM first_open f, c)
    UPDATE public.schedule_lines sl SET due_date = sl.due_date - shift.d
    FROM shift WHERE sl.contract_id = '${contract}'
    RETURNING shift.d;
    COMMIT;`);
  const d = moved.split('\n').find((l) => /^-?\d+$/.test(l));
  if (!d) throw new Error(`contract ${contract} has no open installment`);
  console.log(
    `int5-db: contract ${contract} moved back ${d} days (first open installment ${days} days late)`,
  );
  process.exit(0);
}

if (command !== 'verify' || !args[0]) {
  console.error(
    'usage: node scripts/int5-db.mjs backdate <contract id> <days late> | verify <run.json>',
  );
  process.exit(2);
}

const run = JSON.parse(readFileSync(args[0], 'utf8'));
const org = uuid(run.orgId, 'orgId');
const lifecycle = uuid(run.contracts?.lifecycle, 'contracts.lifecycle');
const settled = uuid(run.contracts?.settled, 'contracts.settled');
const wallet = uuid(run.walletId, 'walletId');
const one = (sql) => psql(sql).split('\n')[0] ?? '';

const checks = [];
const check = (id, title, fn) => {
  try {
    const detail = fn();
    checks.push({ id, title, ok: true, detail });
  } catch (error) {
    checks.push({ id, title, ok: false, detail: error.message });
  }
};
const expectEq = (actual, expected, what) => {
  if (String(actual) !== String(expected))
    throw new Error(`${what}: ${actual}, expected ${expected}`);
};

// D74 / N05: contract total = current lines + paid on superseded lines = total_payable − profit
// waived at settlement (a settlement or reschedule writes a new schedule version).
check('v1', 'every schedule adds up to its contract total, to the piastre', () => {
  const rows = psql(`
    WITH s AS (
      SELECT c.id, c.number, c.total_payable,
             COALESCE((SELECT sum(sl.amount) FROM public.schedule_lines sl
                       WHERE sl.contract_id = c.id AND sl.version = c.current_version), 0)
           + COALESCE((SELECT sum(ls.amount - ls.remaining) FROM public.v_schedule_line_status ls
                       WHERE ls.contract_id = c.id AND ls.superseded), 0) AS schedule,
             COALESCE((SELECT sum(cc.profit_waived) FROM public.contract_changes cc
                       WHERE cc.contract_id = c.id), 0) AS waived
      FROM public.contracts c WHERE c.organization_id = '${org}')
    SELECT number || ' total ' || total_payable || ' waived ' || waived || ' schedule ' || schedule
    FROM s WHERE schedule <> total_payable - waived`);
  if (rows) throw new Error(`schedule differs from total: ${rows}`);
  return `${one(`SELECT count(*) FROM public.contracts WHERE organization_id = '${org}'`)} contracts`;
});

check(
  'v2',
  'no late fee anywhere: no charge rows, every policy version has late_fee_type none',
  () => {
    expectEq(
      one(`SELECT count(*) FROM public.charges WHERE organization_id = '${org}'`),
      0,
      'charges',
    );
    expectEq(
      one(`SELECT count(*) FROM public.installment_policies
         WHERE organization_id = '${org}' AND (late_fee_type <> 'none' OR late_fee_value <> 0)`),
      0,
      'policies with a fee',
    );
    return 'charges 0';
  },
);

check('v3', 'the late contract has one open warning; what it owes did not grow', () => {
  const row = one(`
    SELECT count(*) || ' ' || COALESCE(max(oa.overdue_amount), 0) || ' ' || COALESCE(max(oa.days_late), 0)
    FROM public.overdue_actions oa
    WHERE oa.contract_id = '${lifecycle}' AND oa.kind = 'warning'`);
  const [count, amount, days] = row.split(' ');
  expectEq(count, 1, 'warnings');
  expectEq(Number(amount).toFixed(2), Number(run.overdueAmount).toFixed(2), 'overdue amount');
  const remaining = one(`
    SELECT COALESCE(sum(remaining), 0) FROM public.v_schedule_line_status
    WHERE contract_id = '${lifecycle}' AND NOT superseded`);
  expectEq(
    Number(remaining).toFixed(2),
    Number(run.remainingAfterOverdue).toFixed(2),
    'left to pay',
  );
  return `1 warning, ${amount} overdue, ${days} days late, ${remaining} left`;
});

check('v4', 'the early-settled contract is completed with nothing left', () => {
  expectEq(
    one(`SELECT status FROM public.contracts WHERE id = '${settled}'`),
    'completed',
    'status',
  );
  expectEq(
    Number(
      one(`SELECT COALESCE(sum(remaining), 0) FROM public.v_schedule_line_status
           WHERE contract_id = '${settled}' AND NOT superseded`),
    ).toFixed(2),
    '0.00',
    'left to pay',
  );
  return 'completed, 0.00 left';
});

check('v5', "the collector's wallet equals its cash ledger and the flow's arithmetic", () => {
  const row = one(`
    SELECT b.balance || ' ' || COALESCE((SELECT sum(m.amount) FROM public.cash_movements m
                                         WHERE m.cash_account_id = a.id), 0)
    FROM public.cash_accounts a JOIN public.cash_balances b ON b.cash_account_id = a.id
    WHERE a.id = '${wallet}' AND a.kind = 'collector_wallet'`);
  if (!row) throw new Error('wallet not found');
  const [cached, ledger] = row.split(' ').map((v) => Number(v).toFixed(2));
  expectEq(cached, ledger, 'cached balance vs ledger');
  expectEq(cached, Number(run.walletExpected).toFixed(2), 'wallet balance');
  return `balance ${cached} = ledger ${ledger}`;
});

check('v6', 'every cached balance in the shop matches its ledger (F10 reconciliation)', () => {
  const rows = psql(`
    SELECT concat_ws(' | ', ledger, subject_id, 'cached ' || cached, 'ledger ' || from_ledger)
    FROM app.ledger_mismatches() WHERE organization_id = '${org}'`);
  if (rows) throw new Error(rows);
  return 'no mismatch';
});

for (const c of checks) console.log(`${c.ok ? 'PASS' : 'FAIL'} ${c.id} ${c.title}: ${c.detail}`);
const failed = checks.filter((c) => !c.ok).length;
console.log(`int5-db verify: ${checks.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
