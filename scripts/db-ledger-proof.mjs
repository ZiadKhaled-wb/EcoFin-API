// F10 proof: parallel sales can't oversell, a repeated key changes things once, and every cached
// balance still equals its ledger. Runs against the LOCAL Supabase database container (never a
// hosted project), like db:smoke. Usage: npm run db:ledger   (CI runs it in the db job)
//
// A throwaway shop sells one product with exactly 10 units in stock. The sale routine lives in a
// scratch schema and follows the write-function rules (D33) on the real tables: lock the
// idempotency key, return the existing sale on a repeat, take the document number, insert the
// sale, post the stock and cash movements, all in one transaction. (S01's real post_sale replaces it.)
//   A. 100 sale requests with different keys from SALE_CLIENTS concurrent sessions: exactly 10
//      sell; 90 get OUT_OF_STOCK and leave nothing behind (no sale, no movement, no number).
//   B. 50 concurrent requests with ONE key: one sale, one stock and one cash movement, and the
//      sale took exactly one number.
//   C. app.ledger_mismatches() finds nothing, for the shop and for the whole database.
import { pgbench, processed, psql, removeProofShop, report, writeFile } from './db-proof-lib.mjs';

const SALE_REQUESTS = 100;
const SALE_CLIENTS = Number(process.env.F10_CLIENTS ?? 50); // max_connections is 100 locally
const STOCK = 10;
const PRICE = 100;
const SAME_KEY_CLIENTS = 25;
const SAME_KEY_REQUESTS = 50;

const ORG = 'f1050000-0000-0000-0000-0000000000f1';
const BRANCH = 'f1050000-0000-0000-0000-0000000000b1';
const PRODUCT = 'f1050000-0000-0000-0000-0000000000c1';
const DRAWER = 'f1050000-0000-0000-0000-0000000000d1';
const TAX = 'f1050000-0000-0000-0000-0000000000e1';
const SCHEMA = 'f10_proof';
const SAME_KEY = 'f10-proof-same-key-0001';

function stockIn(quantity) {
  psql(`INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
        VALUES ('${ORG}', '${PRODUCT}', '${BRANCH}', ${quantity}, 'purchase_in', 'purchase_invoice', gen_random_uuid());`);
}

let failed = false;
try {
  if (SALE_REQUESTS % SALE_CLIENTS !== 0)
    throw new Error(`F10_CLIENTS must divide ${SALE_REQUESTS}`);
  removeProofShop(ORG, SCHEMA);
  psql(`
    INSERT INTO public.organizations (id, tenant_slug, name, plan_key, status)
    VALUES ('${ORG}', 'f10-proof', 'F10 ledger proof', 'retail', 'active');
    INSERT INTO public.org_settings (organization_id) VALUES ('${ORG}');
    INSERT INTO public.branches (id, organization_id, code, name, is_main)
    VALUES ('${BRANCH}', '${ORG}', 'PRF', 'Proof branch', true);
    INSERT INTO public.tax_classes (id, organization_id, name, rate) VALUES ('${TAX}', '${ORG}', 'VAT 14', 14);
    INSERT INTO public.products (id, organization_id, name_ar, sku, cash_price, tax_class_id, is_serialized)
    VALUES ('${PRODUCT}', '${ORG}', 'Proof chair', 'F10-PROOF', ${PRICE}, '${TAX}', false);
    INSERT INTO public.cash_accounts (id, organization_id, branch_id, name, kind)
    VALUES ('${DRAWER}', '${ORG}', '${BRANCH}', 'Proof drawer', 'drawer');

    CREATE SCHEMA ${SCHEMA};
    CREATE TABLE ${SCHEMA}.outcomes (
      key     text NOT NULL,
      result  text NOT NULL,          -- sold | out_of_stock | error
      sale_id uuid,
      error   text,
      backend integer NOT NULL DEFAULT pg_backend_pid()
    );

    -- The write-function shape every money/stock function follows (D33).
    CREATE FUNCTION ${SCHEMA}.sell(p_key text) RETURNS uuid LANGUAGE plpgsql AS $$
    DECLARE
      v_id uuid;
    BEGIN
      PERFORM app.lock_idempotency_key('${ORG}', p_key);
      SELECT id INTO v_id FROM public.sales WHERE organization_id = '${ORG}' AND idempotency_key = p_key;
      IF FOUND THEN
        RETURN v_id;
      END IF;
      INSERT INTO public.sales (organization_id, number, branch_id, prices_include_vat, subtotal, total, idempotency_key)
      VALUES ('${ORG}', app.next_document_number('${ORG}', '${BRANCH}', 'sale'), '${BRANCH}', true, ${PRICE}, ${PRICE}, p_key)
      RETURNING id INTO v_id;
      INSERT INTO public.stock_movements (organization_id, product_id, branch_id, quantity, type, source_type, source_id)
      VALUES ('${ORG}', '${PRODUCT}', '${BRANCH}', -1, 'sale_out', 'sale', v_id);
      INSERT INTO public.cash_movements (organization_id, cash_account_id, amount, type, source_type, source_id)
      VALUES ('${ORG}', '${DRAWER}', ${PRICE}, 'sale', 'sale', v_id);
      RETURN v_id;
    END $$;

    -- One request as the API would make it: a refused sale rolls back completely (the block is a
    -- savepoint), then the outcome is recorded for the checks.
    CREATE FUNCTION ${SCHEMA}.request(p_key text) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      v_id uuid;
    BEGIN
      BEGIN
        v_id := ${SCHEMA}.sell(p_key);
        INSERT INTO ${SCHEMA}.outcomes (key, result, sale_id) VALUES (p_key, 'sold', v_id);
      EXCEPTION WHEN others THEN
        INSERT INTO ${SCHEMA}.outcomes (key, result, error)
        VALUES (p_key, CASE WHEN SQLERRM LIKE 'OUT_OF_STOCK%' THEN 'out_of_stock' ELSE 'error' END, SQLERRM);
      END;
    END $$;`);
  stockIn(STOCK);

  // ---------------------------------------------------------------- A. the last 10 units
  writeFile('/tmp/f10_sale.sql', `SELECT ${SCHEMA}.request('f10-proof-' || gen_random_uuid());\n`);
  let started = Date.now();
  const sales = await pgbench('/tmp/f10_sale.sql', SALE_CLIENTS, SALE_REQUESTS / SALE_CLIENTS);
  console.log(
    `A. pgbench: ${processed(sales)} sale requests from ${SALE_CLIENTS} concurrent sessions in ${Date.now() - started} ms`,
  );
  const [
    requests,
    sold,
    outOfStock,
    errors,
    firstError,
    saleRows,
    firstNo,
    lastNo,
    saleMoves,
    onHand,
    balance,
    backends,
  ] = psql(`
    SELECT concat_ws('|',
      (SELECT count(*) FROM ${SCHEMA}.outcomes),
      (SELECT count(*) FROM ${SCHEMA}.outcomes WHERE result = 'sold'),
      (SELECT count(*) FROM ${SCHEMA}.outcomes WHERE result = 'out_of_stock'),
      (SELECT count(*) FROM ${SCHEMA}.outcomes WHERE result = 'error'),
      COALESCE((SELECT error FROM ${SCHEMA}.outcomes WHERE result = 'error' LIMIT 1), '-'),
      (SELECT count(*) FROM public.sales WHERE organization_id = '${ORG}'),
      (SELECT min(right(number, 6)::integer) FROM public.sales WHERE organization_id = '${ORG}'),
      (SELECT max(right(number, 6)::integer) FROM public.sales WHERE organization_id = '${ORG}'),
      (SELECT count(*) FROM public.stock_movements WHERE organization_id = '${ORG}' AND type = 'sale_out'),
      (SELECT on_hand FROM public.stock_levels WHERE organization_id = '${ORG}' AND product_id = '${PRODUCT}'),
      (SELECT balance FROM public.cash_balances WHERE cash_account_id = '${DRAWER}'),
      (SELECT count(DISTINCT backend) FROM ${SCHEMA}.outcomes));`).split('|');

  const partA = report([
    [`${SALE_REQUESTS} sale requests were made`, Number(requests) === SALE_REQUESTS, requests],
    [`exactly ${STOCK} sold`, Number(sold) === STOCK, sold],
    [
      `the other ${SALE_REQUESTS - STOCK} got OUT_OF_STOCK`,
      Number(outOfStock) === SALE_REQUESTS - STOCK,
      outOfStock,
    ],
    [
      'no other errors (no deadlocks, no duplicates)',
      Number(errors) === 0,
      `${errors} ${firstError}`,
    ],
    [
      `${STOCK} sale documents and ${STOCK} stock movements`,
      Number(saleRows) === STOCK && Number(saleMoves) === STOCK,
      `${saleRows} / ${saleMoves}`,
    ],
    [
      `refused sales took no number: sales are 000001..${String(STOCK).padStart(6, '0')}`,
      firstNo === '1' && lastNo === String(STOCK),
      `${firstNo}..${lastNo}`,
    ],
    ['stock is exactly 0, never below', onHand === '0', onHand],
    [`the drawer holds ${STOCK} x ${PRICE}`, Number(balance) === STOCK * PRICE, balance],
    [
      'the requests came from many concurrent sessions',
      Number(backends) >= Math.min(SALE_CLIENTS, 10),
      `${backends} sessions`,
    ],
  ]);

  // ---------------------------------------------------------------- B. one key, many requests
  stockIn(5);
  psql(`TRUNCATE ${SCHEMA}.outcomes;`);
  writeFile('/tmp/f10_same_key.sql', `SELECT ${SCHEMA}.request('${SAME_KEY}');\n`);
  started = Date.now();
  const repeats = await pgbench(
    '/tmp/f10_same_key.sql',
    SAME_KEY_CLIENTS,
    SAME_KEY_REQUESTS / SAME_KEY_CLIENTS,
  );
  console.log(
    `B. pgbench: ${processed(repeats)} requests with one key from ${SAME_KEY_CLIENTS} concurrent sessions in ${Date.now() - started} ms`,
  );
  const [answered, allSold, saleIds, keyRows, keyStock, keyCash, keyNo, onHandAfter, balanceAfter] =
    psql(`
    SELECT concat_ws('|',
      (SELECT count(*) FROM ${SCHEMA}.outcomes),
      (SELECT bool_and(result = 'sold') FROM ${SCHEMA}.outcomes),
      (SELECT count(DISTINCT sale_id) FROM ${SCHEMA}.outcomes),
      (SELECT count(*) FROM public.sales WHERE organization_id = '${ORG}' AND idempotency_key = '${SAME_KEY}'),
      (SELECT count(*) FROM public.stock_movements m JOIN public.sales s ON s.id = m.source_id WHERE s.idempotency_key = '${SAME_KEY}'),
      (SELECT count(*) FROM public.cash_movements m JOIN public.sales s ON s.id = m.source_id WHERE s.idempotency_key = '${SAME_KEY}'),
      (SELECT right(number, 6)::integer FROM public.sales WHERE organization_id = '${ORG}' AND idempotency_key = '${SAME_KEY}'),
      (SELECT on_hand FROM public.stock_levels WHERE organization_id = '${ORG}' AND product_id = '${PRODUCT}'),
      (SELECT balance FROM public.cash_balances WHERE cash_account_id = '${DRAWER}'));`).split('|');

  const partB = report([
    [
      `all ${SAME_KEY_REQUESTS} requests got an answer, every one "sold"`,
      Number(answered) === SAME_KEY_REQUESTS && allSold === 't',
      `${answered} ${allSold}`,
    ],
    ['all of them got the same sale', saleIds === '1', `${saleIds} distinct`],
    [
      'one sale, one stock movement, one cash movement',
      keyRows === '1' && keyStock === '1' && keyCash === '1',
      `${keyRows} / ${keyStock} / ${keyCash}`,
    ],
    [
      `the repeats took no number: the sale is ${String(STOCK + 1).padStart(6, '0')}`,
      keyNo === String(STOCK + 1),
      keyNo,
    ],
    ['stock went down by 1 only (5 -> 4)', onHandAfter === '4', onHandAfter],
    [`cash went up by ${PRICE} only`, Number(balanceAfter) === (STOCK + 1) * PRICE, balanceAfter],
  ]);

  // ---------------------------------------------------------------- C. reconciliation
  const [shopMismatches, allMismatches] = psql(`
    SELECT concat_ws('|', (SELECT count(*) FROM app.ledger_mismatches('${ORG}')), (SELECT count(*) FROM app.ledger_mismatches()));`).split(
    '|',
  );
  const partC = report([
    [
      'C. the proof shop reconciles: every cache = its ledger',
      shopMismatches === '0',
      `${shopMismatches} mismatches`,
    ],
    ['C. the whole database reconciles', allMismatches === '0', `${allMismatches} mismatches`],
  ]);

  failed = !(partA && partB && partC);
} catch (error) {
  console.error(`db:ledger: ${error.message}`);
  failed = true;
} finally {
  try {
    removeProofShop(ORG, SCHEMA);
  } catch (error) {
    console.error(`db:ledger: cleanup failed: ${error.message}`);
    failed = true;
  }
}

console.log(failed ? 'db:ledger: FAILED' : 'db:ledger: passed');
process.exit(failed ? 1 : 0);
