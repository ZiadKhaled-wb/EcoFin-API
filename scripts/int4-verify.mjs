// INT-4 (EC-133): the database checks of the cash-sale flow. LOCAL ONLY.
// Reads with the service role (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY: the shell or .env.local),
// and the fake ETA's counts from its local admin route (FAKE_ETA_ADMIN_URL, default
// http://127.0.0.1:4011). Prints PASS/FAIL per check and exits 1 when one fails.
//   node scripts/int4-verify.mjs <run.json>
// <run.json> is written by EcoFin-Web/e2e/int4-cash-sale.spec.ts: the ids the flow made.
import { existsSync, readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

if (existsSync('.env.local')) {
  for (const line of readFileSync('.env.local', 'utf8').split(/\r?\n/)) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
  }
}
const url = process.env.SUPABASE_URL ?? '';
if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(url)) {
  console.error('int4-verify: SUPABASE_URL must be the LOCAL stack');
  process.exit(2);
}
const runFile = process.argv[2];
if (!runFile) {
  console.error('usage: node scripts/int4-verify.mjs <run.json>');
  process.exit(2);
}
const run = JSON.parse(readFileSync(runFile, 'utf8'));
const db = createClient(url, process.env.SUPABASE_SERVICE_ROLE_KEY ?? '', {
  auth: { persistSession: false, autoRefreshToken: false },
});
const adminUrl = process.env.FAKE_ETA_ADMIN_URL ?? 'http://127.0.0.1:4011';
const fake = await (await fetch(`${adminUrl}/admin/state`)).json();
const fakeReceipt = (uuid) => fake.receipts.find((r) => r.uuid === uuid);

let failed = 0;
const results = [];
async function check(id, name, fn) {
  if (typeof fn !== 'function') {
    failed += 1;
    results.push(`FAIL ${id} ${name}: no ids from the flow (the check before it failed)`);
    return;
  }
  try {
    const detail = await fn();
    results.push(`PASS ${id} ${name}${detail ? `: ${detail}` : ''}`);
  } catch (e) {
    failed += 1;
    results.push(`FAIL ${id} ${name}: ${e instanceof Error ? e.message : String(e)}`);
  }
}
function assert(ok, message) {
  if (!ok) throw new Error(message);
}
async function rows(table, filter, select = '*') {
  let q = db.from(table).select(select);
  for (const [k, v] of Object.entries(filter)) q = Array.isArray(v) ? q.in(k, v) : q.eq(k, v);
  const { data, error } = await q;
  if (error) throw new Error(`${table}: ${error.message}`);
  return data;
}
const one = async (table, filter, select) => {
  const r = await rows(table, filter, select);
  assert(r.length === 1, `${table} ${JSON.stringify(filter)}: ${r.length} rows`);
  return r[0];
};
const cents = (v) => Math.round(Number(v) * 100);
const fiscalOf = (saleId) =>
  one('fiscal_submissions', { sale_id: saleId, doc_type: 'b2c_receipt' });
const seq = (number) => Number(/(\d+)$/.exec(number)?.[1] ?? NaN);

await check(
  'c',
  'the approval is bound to the sale and used once',
  run.approvalSaleId &&
    (async () => {
      const a = await one('approvals', { entity_id: run.approvalSaleId });
      assert(
        a.entity_id === run.approvalSaleId,
        `approvals.entity_id=${a.entity_id}, sale=${run.approvalSaleId}`,
      );
      const sales = await rows('sales', { id: run.approvalSaleId }, 'id');
      assert(sales.length === 1, 'the approved sale is missing');
      return `approvals.entity_id = ${a.entity_id} (status ${a.status})`;
    }),
);

await check(
  'd',
  'a double-clicked Pay made one sale',
  run.splitSaleId &&
    (async () => {
      const { idempotency_key: key } = await one(
        'sales',
        { id: run.splitSaleId },
        'idempotency_key',
      );
      const s = await rows('sales', { idempotency_key: key }, 'id, number');
      assert(s.length === 1, `${s.length} sales for the key`);
      return `1 sale (${s[0].number}) for the idempotency key`;
    }),
);

await check(
  'e',
  'one transaction: stock, unit, drawer, bank, tax, number, audit',
  run.splitSaleId &&
    (async () => {
      const sale = await one('sales', { id: run.splitSaleId });
      const lines = await rows('sale_lines', { sale_id: sale.id });
      const moves = await rows('stock_movements', { source_id: sale.id, source_type: 'sale' });
      for (const l of lines) {
        const q = moves
          .filter((m) => m.product_id === l.product_id)
          .reduce((n, m) => n + m.quantity, 0);
        assert(q === -l.quantity, `product ${l.product_id}: stock ${q}, sold ${l.quantity}`);
        if (l.unit_id) {
          const u = await one('units', { id: l.unit_id });
          // Sold by this sale; a later warranty claim (check k) may have taken it back since.
          const claimed =
            run.claimId && (await one('warranty_claims', { id: run.claimId })).unit_id === u.id;
          assert(
            u.status === 'sold' || (claimed && u.status !== 'in_stock'),
            `unit ${u.serial} is ${u.status}`,
          );
        }
      }
      const cash = await rows('cash_movements', { source_id: sale.id, source_type: 'sale' });
      const accounts = await rows(
        'cash_accounts',
        { id: cash.map((c) => c.cash_account_id) },
        'id, kind',
      );
      const kind = (c) => accounts.find((a) => a.id === c.cash_account_id)?.kind;
      const drawer = cash
        .filter((c) => kind(c) === 'drawer')
        .reduce((n, c) => n + cents(c.amount), 0);
      const bank = cash.filter((c) => kind(c) === 'bank').reduce((n, c) => n + cents(c.amount), 0);
      assert(drawer === cents(run.cashPart), `drawer +${drawer / 100}, expected ${run.cashPart}`);
      assert(bank === cents(run.transferPart), `bank +${bank / 100}, expected ${run.transferPart}`);
      assert(
        drawer + bank === cents(sale.total),
        `drawer + bank ${(drawer + bank) / 100} != total ${sale.total}`,
      );
      // T01: VAT inside the price (prices_include_vat) or on top, per line, rounded to the piastre.
      const lineTax = lines.reduce((n, l) => n + cents(l.tax_amount), 0);
      assert(
        lineTax === cents(sale.tax_total),
        `tax_total ${sale.tax_total} != sum of lines ${lineTax / 100}`,
      );
      for (const l of lines) {
        const rate = Number(l.tax_rate);
        const total = Number(l.line_total);
        const expected = sale.prices_include_vat
          ? (total * rate) / (100 + rate)
          : (total * rate) / 100;
        assert(
          Math.abs(cents(l.tax_amount) - Math.round(expected * 100)) <= 1,
          `line ${l.line_no}: tax ${l.tax_amount}, T01 gives ${expected.toFixed(2)}`,
        );
      }
      const branchSales = (await rows('sales', { branch_id: sale.branch_id }, 'number, created_at'))
        .filter((s) => s.created_at < sale.created_at)
        .sort((a, b) => (a.created_at < b.created_at ? -1 : 1));
      const before = branchSales.at(-1);
      assert(
        !before || seq(sale.number) === seq(before.number) + 1,
        `number ${sale.number} after ${before?.number}`,
      );
      const audit = await rows('audit_log', { entity_id: sale.id }, 'action');
      assert(audit.length >= 1, 'no audit row for the sale');
      return (
        `stock ok, drawer +${drawer / 100}, bank +${bank / 100}, tax_total ${sale.tax_total}, ` +
        `number ${sale.number} (after ${before?.number ?? 'none'}), audit ${audit.map((a) => a.action).join(',')}`
      );
    }),
);

await check(
  'f',
  'ETA: accepted, same UUID at the fake, chained, sent once',
  run.shiftSaleIds &&
    (async () => {
      const [s1, s2] = run.shiftSaleIds;
      const f1 = await fiscalOf(s1);
      const f2 = await fiscalOf(s2);
      for (const f of [f1, f2]) {
        assert(f.status === 'accepted', `fiscal ${f.internal_id} is ${f.status} (${f.last_error})`);
        const r = fakeReceipt(f.eta_uuid);
        assert(r && r.status === 'Valid', `the fake has no Valid receipt ${f.eta_uuid}`);
        assert(
          fake.received[f.eta_uuid] === 1,
          `the fake received ${f.eta_uuid} ${fake.received[f.eta_uuid]} times`,
        );
      }
      assert(
        f2.previous_uuid === f1.eta_uuid,
        `sale 2 previousUUID ${f2.previous_uuid} != sale 1 ${f1.eta_uuid}`,
      );
      assert(
        fakeReceipt(f2.eta_uuid).previousUuid === f1.eta_uuid,
        'the fake saw another previousUUID',
      );
      assert(fake.badHashes.length === 0, `the fake recomputed other UUIDs for ${fake.badHashes}`);
      assert(fake.chainBreaks.length === 0, `chain breaks at the fake: ${fake.chainBreaks}`);
      return `${f1.eta_uuid.slice(0, 12)}… -> ${f2.eta_uuid.slice(0, 12)}…, each received once, 0 bad hashes`;
    }),
);

await check(
  'g',
  'the receipt QR text carries the fiscal UUID',
  run.splitSaleId &&
    (async () => {
      const f = await fiscalOf(run.splitSaleId);
      assert(
        f.eta_uuid && String(f.qr_payload ?? '').includes(f.eta_uuid),
        `qr_payload lacks ${f.eta_uuid}`,
      );
      return `qr_payload contains ${f.eta_uuid.slice(0, 12)}…`;
    }),
);

await check(
  'h',
  'rejected -> corrected with referenceOldUUID',
  run.rejectedSaleId &&
    (async () => {
      const f = await fiscalOf(run.rejectedSaleId);
      assert(f.status === 'accepted', `fiscal is ${f.status}`);
      assert(
        f.reference_old_uuid === run.rejectedOldUuid,
        `reference_old_uuid ${f.reference_old_uuid}`,
      );
      const r = fakeReceipt(f.eta_uuid);
      assert(
        r?.status === 'Valid' && r.referenceOldUuid === run.rejectedOldUuid,
        'the fake did not get the correction',
      );
      assert(
        fakeReceipt(run.rejectedOldUuid)?.status === 'Invalid',
        'the old receipt is not Invalid at the fake',
      );
      return `new ${f.eta_uuid.slice(0, 12)}… referenceOldUUID = ${run.rejectedOldUuid.slice(0, 12)}…`;
    }),
);

await check(
  'i',
  'blocked ITEM_CODE -> fixed -> accepted',
  run.blockedSaleId &&
    (async () => {
      const f = await fiscalOf(run.blockedSaleId);
      assert(f.status === 'accepted', `fiscal is ${f.status} (${f.last_error})`);
      const events = await rows('fiscal_events', { fiscal_id: f.id });
      assert(JSON.stringify(events).includes('ITEM_CODE'), 'no BLOCKED:ITEM_CODE event');
      return `accepted after ${events.length} events, one of them BLOCKED:ITEM_CODE`;
    }),
);

await check(
  'j',
  'void in shop B puts stock and cash back',
  run.voidSaleId &&
    (async () => {
      const moves = await rows('stock_movements', {
        source_id: run.voidSaleId,
        source_type: 'sale',
      });
      const back = await rows('stock_movements', { reverses_movement_id: moves.map((m) => m.id) });
      const net = [...moves, ...back].reduce((n, m) => n + m.quantity, 0);
      assert(moves.length > 0 && net === 0, `stock net ${net} after the void`);
      const cash = await rows('cash_movements', { source_id: run.voidSaleId, source_type: 'sale' });
      const refunds = await rows('cash_movements', { reverses_movement_id: cash.map((c) => c.id) });
      const cashNet = [...cash, ...refunds].reduce((n, c) => n + cents(c.amount), 0);
      assert(cash.length > 0 && cashNet === 0, `cash net ${cashNet / 100} after the void`);
      return `stock net 0 (${moves.length}+${back.length} movements), cash net 0`;
    }),
);

await check(
  'k',
  'warranty replacement: damaged +1, sellable -1',
  run.claimId &&
    (async () => {
      const c = await one('warranty_claims', { id: run.claimId });
      assert(c.replacement_unit_id, `claim ${c.number} has no replacement (status ${c.status})`);
      const moves = await rows('stock_movements', { source_id: run.claimId });
      const damaged = moves
        .filter((m) => m.stock_state === 'damaged')
        .reduce((n, m) => n + m.quantity, 0);
      const sellable = moves
        .filter((m) => m.stock_state === 'sellable')
        .reduce((n, m) => n + m.quantity, 0);
      assert(damaged === 1 && sellable === -1, `damaged ${damaged}, sellable ${sellable}`);
      return `claim ${c.number} ${c.status}: damaged +1, sellable -1`;
    }),
);

await check(
  'm',
  'the last unit was sold once',
  run.lastProductId &&
    (async () => {
      const lines = await rows('sale_lines', { product_id: run.lastProductId }, 'quantity');
      const level = await rows(
        'stock_levels',
        { product_id: run.lastProductId },
        'on_hand, stock_state',
      );
      const sellable = level
        .filter((l) => l.stock_state === 'sellable')
        .reduce((n, l) => n + l.on_hand, 0);
      assert(
        lines.length === 1 && sellable === 0,
        `${lines.length} sale lines, sellable ${sellable}`,
      );
      return '1 sale line, sellable stock 0';
    }),
);

await check(
  'o',
  'fiscal_day_summary counts every receipt',
  run.daySummary &&
    (async () => {
      const fiscal = await rows(
        'fiscal_submissions',
        { branch_id: run.branchA, doc_type: 'b2c_receipt' },
        'status, sale_id',
      );
      const s = run.daySummary;
      assert(s.total >= fiscal.length, `summary total ${s.total} < ${fiscal.length} receipts`);
      const open = fiscal.filter((f) => !['accepted', 'cancelled'].includes(f.status));
      assert(
        s.all_accepted === (open.length === 0),
        `all_accepted ${s.all_accepted} with ${open.length} open`,
      );
      return `total ${s.total}, accepted ${s.accepted}, all_accepted ${s.all_accepted}`;
    }),
);

for (const line of results) console.log(line);
console.log(`int4-verify: ${results.length - failed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
