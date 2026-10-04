// F10 reconciliation check: every cached balance (stock on hand and reserved, cash, store credit)
// must equal the sum of its ledger, in every shop. Runs app.ledger_mismatches() on the LOCAL
// Supabase database and fails (exit 1) on any mismatch. CI runs it after the full test suite.
// Usage: npm run db:reconcile
import { psql } from './db-proof-lib.mjs';

try {
  const rows = psql(`
    SELECT concat_ws(' | ', ledger, organization_id, subject_id, COALESCE(branch_id::text, '-'),
                     COALESCE(detail, '-'), 'cached ' || cached, 'ledger ' || from_ledger)
    FROM app.ledger_mismatches()
    ORDER BY ledger, organization_id, subject_id;`);
  const counts = psql(`
    SELECT concat_ws(' / ',
      (SELECT count(*) || ' stock levels' FROM public.stock_levels),
      (SELECT count(*) || ' cash balances' FROM public.cash_balances),
      (SELECT count(*) || ' store credit balances' FROM public.store_credit_balances));`);
  if (rows) {
    console.error(`db:reconcile: FAILED, caches that don't match their ledger:\n${rows}`);
    process.exit(1);
  }
  console.log(`db:reconcile: passed (every cache matches its ledger: ${counts})`);
} catch (error) {
  console.error(`db:reconcile: ${error.message}`);
  process.exit(1);
}
