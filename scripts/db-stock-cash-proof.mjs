// TEST-3 proof (EC-132): the REAL Sprint 3 write functions under parallel load. Two requests for
// the last unit, or for the last pound in a safe, at the same moment: one succeeds, the others
// are refused, and nothing goes below zero. Runs against the LOCAL Supabase database container
// (never a hosted project), like db:ledger. Usage: npm run db:stock-cash   (CI: the db job)
//
// A throwaway shop (provisioned like any shop, its owner signed in) holds one chair, one phone
// with an IMEI, and a safe with 1 000.00. Every request runs as the owner through the public
// functions the API calls, each in its own session and transaction:
//   A. 20 stock adjustments (loss of 1) for the last chair: exactly one posts.
//   B. 20 write-offs of the same IMEI unit: exactly one posts; the unit left stock once.
//   C. the last chair again, 10 adjustments racing 10 branch transfers: exactly one of the 20 wins.
//   D. 20 expenses of 1 000.00 from the safe that holds 1 000.00: exactly one is paid.
// Then real sales (S01, public.post_sale) by four cashiers, each in their own open shift:
//   F. 20 sales of the last chair: exactly one sells, 19 get OUT_OF_STOCK.
//   G. 20 sales of one IMEI unit: exactly one sells.
//   H. 20 requests with ONE idempotency key: one sale, one stock and one cash movement, one number.
//   I. 20 two-product carts, half listing chair then lamp and half lamp then chair, for 10 of
//      each: exactly 10 sell and nothing deadlocks (rows are always locked in the same order).
//   E. app.ledger_mismatches() finds nothing, for the shop and for the whole database, and the
//      sales' totals equal their payments and the drawers' sale movements.
//   J. S02: 20 sales each paying a lamp with the same customer's store credit (exactly one lamp's
//      worth): one is paid, the balance ends at 0.00, never below.
// (The sale race on the bare ledger is db:ledger, F10.)
import { pgbench, processed, psql, removeProofShop, report, writeFile } from './db-proof-lib.mjs';

const CLIENTS = Number(process.env.TEST3_CLIENTS ?? 20);
const SLUG = 'test3-proof';
const SCHEMA = 'test3_proof';
const ADMIN = 'f0000000-0000-0000-0000-000000000001'; // the seeded platform admin
const OWNER = 'f3030000-0000-0000-8000-000000000001';
const OWNER_EMAIL = 'test3-proof-owner@example.com';
const TOKEN = 'f'.repeat(64);
const CASHIERS = 4;
const cashier = (n) => `f3030000-0000-0000-8000-00000000001${n}`;

/** Removes what an earlier (interrupted) run left behind. */
function cleanUp() {
  const org = psql(`SELECT id FROM public.organizations WHERE tenant_slug = '${SLUG}';`);
  if (org) removeProofShop(org, SCHEMA);
  psql(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE;
        DELETE FROM auth.users WHERE id = '${OWNER}' OR id::text LIKE 'f3030000-0000-0000-8000-00000000001_';`);
}

/** Counts of the outcomes of one round: [done, refused with `code`, anything else, first other error]. */
function outcomes(kinds, code) {
  return psql(`
    SELECT concat_ws('|',
      count(*) FILTER (WHERE result = 'done'),
      count(*) FILTER (WHERE result = 'refused' AND split_part(error, ':', 1) = ANY('{${code}}')),
      count(*) FILTER (WHERE result = 'refused' AND NOT split_part(error, ':', 1) = ANY('{${code}}')),
      COALESCE(min(error) FILTER (WHERE result = 'refused' AND NOT split_part(error, ':', 1) = ANY('{${code}}')), '-'),
      count(DISTINCT backend))
    FROM ${SCHEMA}.outcomes WHERE kind = ANY('{${kinds}}');`).split('|');
}

async function round(label, script, sql) {
  writeFile(script, sql);
  const started = Date.now();
  const out = await pgbench(script, CLIENTS, 1);
  console.log(
    `${label} pgbench: ${processed(out)} requests from ${CLIENTS} concurrent sessions in ${Date.now() - started} ms`,
  );
}

let failed = false;
try {
  cleanUp();
  // The shop, as the platform admin provisions it; then its owner accepts the invite and sets up.
  psql(`
    SELECT set_config('request.jwt.claim.sub', '${ADMIN}', false);
    SELECT public.admin_provision_organization('TEST-3 proof', '${SLUG}', 'retail_pro', 'Owner',
             '${OWNER_EMAIL}', NULL, 'Main', '${TOKEN}', now() + interval '1 day');
    INSERT INTO auth.users (id, email) VALUES ('${OWNER}', '${OWNER_EMAIL}');
    SELECT public.accept_invite('${TOKEN}', '${OWNER}');

    CREATE SCHEMA ${SCHEMA};
    CREATE TABLE ${SCHEMA}.ids (tag text PRIMARY KEY, id uuid NOT NULL);
    INSERT INTO ${SCHEMA}.ids SELECT 'org', id FROM public.organizations WHERE tenant_slug = '${SLUG}';
    INSERT INTO ${SCHEMA}.ids SELECT 'main', b.id FROM public.branches b, ${SCHEMA}.ids o
      WHERE o.tag = 'org' AND b.organization_id = o.id AND b.is_main;
    INSERT INTO ${SCHEMA}.ids SELECT 'safe', b.default_cash_account_id FROM public.branches b, ${SCHEMA}.ids m
      WHERE m.tag = 'main' AND b.id = m.id;
    CREATE FUNCTION ${SCHEMA}.id(p text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM ${SCHEMA}.ids WHERE tag = p $$;
    -- Signs the owner in for the current transaction, as the API does for a request.
    CREATE FUNCTION ${SCHEMA}.sign_in() RETURNS void LANGUAGE sql AS $$
      SELECT set_config('request.jwt.claim.sub', '${OWNER}', true), set_config('app.org_id', '', true),
             set_config('request.headers', json_build_object('x-org-id', ${SCHEMA}.id('org'))::text, true) $$;
    CREATE TABLE ${SCHEMA}.outcomes (
      kind    text NOT NULL,
      result  text NOT NULL,          -- done | refused
      error   text,
      ref     uuid,                   -- the sale a "done" sale request answered
      backend integer NOT NULL DEFAULT pg_backend_pid()
    );

    BEGIN;
    SELECT ${SCHEMA}.sign_in();
    INSERT INTO ${SCHEMA}.ids VALUES ('north', public.create_branch('North', 'NTH', NULL, NULL, NULL, NULL, NULL));
    INSERT INTO ${SCHEMA}.ids VALUES ('chair', public.create_product('{"name_ar":"Proof chair","sku":"T3P-CH","cash_price":"250"}'));
    INSERT INTO ${SCHEMA}.ids VALUES ('phone', public.create_product('{"name_ar":"Proof phone","sku":"T3P-PH","cash_price":"5000","is_serialized":true}'));
    INSERT INTO ${SCHEMA}.ids SELECT 'category', (public.create_expense_category('Proof')->>'id')::uuid;
    SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL,
             jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 1)), 'test3-proof-chair-1');
    SELECT public.register_units(${SCHEMA}.id('phone'), ${SCHEMA}.id('main'), '3000.00', '["T3P-IMEI-1"]', NULL, 'test3-proof-unit');
    INSERT INTO ${SCHEMA}.ids SELECT 'unit', id FROM public.units WHERE organization_id = ${SCHEMA}.id('org') AND serial = 'T3P-IMEI-1';
    SELECT public.post_cash_opening(${SCHEMA}.id('safe'), '1000.00', 'Proof opening', 'test3-proof-opening');
    COMMIT;

    -- One request as the API makes it: the owner calls the real function; a refusal rolls the
    -- whole call back (the block is a savepoint) and the outcome is recorded for the checks.
    CREATE FUNCTION ${SCHEMA}.request(p_kind text) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      v_key text := 'test3-proof-' || gen_random_uuid();
    BEGIN
      PERFORM ${SCHEMA}.sign_in();
      BEGIN
        IF p_kind = 'chair' THEN
          PERFORM public.post_stock_adjustment(${SCHEMA}.id('main'), 'loss', NULL,
            jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', -1)), v_key);
        ELSIF p_kind = 'unit' THEN
          PERFORM public.post_stock_adjustment(${SCHEMA}.id('main'), 'loss', NULL,
            jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('phone'), 'unit_id', ${SCHEMA}.id('unit'), 'quantity', -1)), v_key);
        ELSIF p_kind = 'transfer' THEN
          PERFORM public.send_stock_transfer((public.create_stock_transfer(${SCHEMA}.id('main'), ${SCHEMA}.id('north'), NULL,
            jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 1)), v_key)->>'id')::uuid);
        ELSIF p_kind = 'expense' THEN
          PERFORM public.post_expense(${SCHEMA}.id('category'), '1000.00', v_key, ${SCHEMA}.id('main'), ${SCHEMA}.id('safe'));
        ELSE
          RAISE EXCEPTION 'unknown kind %', p_kind;
        END IF;
        INSERT INTO ${SCHEMA}.outcomes (kind, result) VALUES (p_kind, 'done');
      EXCEPTION WHEN others THEN
        INSERT INTO ${SCHEMA}.outcomes (kind, result, error) VALUES (p_kind, 'refused', SQLERRM);
      END;
    END $$;`);

  const level = (product, branch = 'main') =>
    psql(`SELECT COALESCE((SELECT on_hand FROM public.stock_levels
                           WHERE product_id = ${SCHEMA}.id('${product}') AND branch_id = ${SCHEMA}.id('${branch}')), 0);`);

  // ---------------------------------------------------------------- A. the last chair
  await round('A.', '/tmp/test3_chair.sql', `SELECT ${SCHEMA}.request('chair');\n`);
  let [done, refused, other, firstOther, backends] = outcomes('chair', 'OUT_OF_STOCK');
  const lossDocs = psql(`SELECT count(*) FROM public.stock_adjustments
                         WHERE organization_id = ${SCHEMA}.id('org') AND reason = 'loss';`);
  const partA = report([
    [
      `A. ${CLIENTS} adjustments asked for the last chair`,
      Number(done) + Number(refused) + Number(other) === CLIENTS,
      `${done}+${refused}+${other}`,
    ],
    ['A. exactly one posted', done === '1', done],
    [`A. the other ${CLIENTS - 1} got OUT_OF_STOCK`, Number(refused) === CLIENTS - 1, refused],
    ['A. no other errors (no deadlocks)', other === '0', `${other} ${firstOther}`],
    ['A. one loss document; the refused ones left nothing', lossDocs === '1', lossDocs],
    ['A. the chair is at exactly 0, never below', level('chair') === '0', level('chair')],
    [
      'A. the requests came from many concurrent sessions',
      Number(backends) >= Math.min(CLIENTS, 10),
      `${backends} sessions`,
    ],
  ]);

  // ---------------------------------------------------------------- B. one IMEI unit
  await round('B.', '/tmp/test3_unit.sql', `SELECT ${SCHEMA}.request('unit');\n`);
  [done, refused, other, firstOther] = outcomes('unit', 'UNIT_NOT_AVAILABLE,OUT_OF_STOCK');
  const [unitStatus, unitOut] = psql(`
    SELECT concat_ws('|', (SELECT status FROM public.units WHERE id = ${SCHEMA}.id('unit')),
      (SELECT count(*) FROM public.stock_movements WHERE unit_id = ${SCHEMA}.id('unit') AND quantity < 0));`).split(
    '|',
  );
  const partB = report([
    ['B. exactly one write-off of the unit posted', done === '1', done],
    [
      `B. the other ${CLIENTS - 1} were refused (the unit is no longer in stock)`,
      Number(refused) === CLIENTS - 1,
      refused,
    ],
    ['B. no other errors', other === '0', `${other} ${firstOther}`],
    [
      'B. the unit left stock exactly once',
      unitOut === '1' && unitStatus !== 'in_stock',
      `${unitOut} movement, ${unitStatus}`,
    ],
    ['B. the phone is at exactly 0', level('phone') === '0', level('phone')],
  ]);

  // ---------------------------------------------------------------- C. an adjustment races a transfer
  psql(`BEGIN; SELECT ${SCHEMA}.sign_in();
        SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL,
          jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 1)), 'test3-proof-chair-2');
        COMMIT; TRUNCATE ${SCHEMA}.outcomes;`);
  await round(
    'C.',
    '/tmp/test3_mixed.sql',
    `\\set r random(1, 2)\nSELECT ${SCHEMA}.request(CASE :r WHEN 1 THEN 'chair' ELSE 'transfer' END);\n`,
  );
  [done, refused, other, firstOther] = outcomes('chair,transfer', 'OUT_OF_STOCK');
  const [kindsAsked, transfers, sent] = psql(`
    SELECT concat_ws('|', (SELECT count(DISTINCT kind) FROM ${SCHEMA}.outcomes),
      (SELECT count(*) FROM public.stock_transfers WHERE organization_id = ${SCHEMA}.id('org')),
      (SELECT count(*) FROM public.stock_transfers WHERE organization_id = ${SCHEMA}.id('org') AND status::text <> 'draft'));`).split(
    '|',
  );
  const partC = report([
    [
      'C. adjustments and transfers both asked for the last chair',
      kindsAsked === '2',
      `${kindsAsked} kinds`,
    ],
    ['C. exactly one of them got it', done === '1', done],
    [`C. the other ${CLIENTS - 1} got OUT_OF_STOCK`, Number(refused) === CLIENTS - 1, refused],
    ['C. no other errors', other === '0', `${other} ${firstOther}`],
    [
      'C. a refused transfer left no document behind',
      transfers === sent && Number(transfers) <= 1,
      `${transfers} transfers, ${sent} sent`,
    ],
    ['C. the chair is at exactly 0 in main', level('chair') === '0', level('chair')],
  ]);

  // ---------------------------------------------------------------- D. the last 1 000.00 in the safe
  await round('D.', '/tmp/test3_expense.sql', `SELECT ${SCHEMA}.request('expense');\n`);
  [done, refused, other, firstOther] = outcomes('expense', 'INSUFFICIENT_FUNDS');
  const [expenses, firstNo, balance, cashRows] = psql(`
    SELECT concat_ws('|',
      (SELECT count(*) FROM public.expenses WHERE organization_id = ${SCHEMA}.id('org')),
      (SELECT min(right(number, 6)::integer) || '..' || max(right(number, 6)::integer) FROM public.expenses WHERE organization_id = ${SCHEMA}.id('org')),
      (SELECT balance FROM public.cash_balances WHERE cash_account_id = ${SCHEMA}.id('safe')),
      (SELECT count(*) FROM public.cash_movements WHERE cash_account_id = ${SCHEMA}.id('safe') AND type = 'expense'));`).split(
    '|',
  );
  const partD = report([
    ['D. exactly one expense was paid', done === '1', done],
    [
      `D. the other ${CLIENTS - 1} got INSUFFICIENT_FUNDS`,
      Number(refused) === CLIENTS - 1,
      refused,
    ],
    ['D. no other errors', other === '0', `${other} ${firstOther}`],
    [
      'D. one expense and one cash movement; the refused ones took no number',
      expenses === '1' && cashRows === '1' && firstNo === '1..1',
      `${expenses} / ${cashRows} / ${firstNo}`,
    ],
    ['D. the safe is at exactly 0.00, never below', Number(balance) === 0, balance],
  ]);

  // ---------------------------------------------------------------- real sales: four cashiers, four shifts
  psql(`
    INSERT INTO auth.users (id, email)
    SELECT ('f3030000-0000-0000-8000-00000000001' || n)::uuid, 'test3-proof-cashier-' || n || '@example.com'
    FROM generate_series(1, ${CASHIERS}) n;
    INSERT INTO public.employees (organization_id, auth_user_id, full_name, role, default_branch_id)
    SELECT ${SCHEMA}.id('org'), ('f3030000-0000-0000-8000-00000000001' || n)::uuid, 'Proof cashier ' || n,
           'CASHIER', ${SCHEMA}.id('main') FROM generate_series(1, ${CASHIERS}) n;
    INSERT INTO public.employee_branches (organization_id, employee_id, branch_id)
    SELECT e.organization_id, e.id, ${SCHEMA}.id('main') FROM public.employees e
    WHERE e.organization_id = ${SCHEMA}.id('org') AND e.role = 'CASHIER';
    -- O03: a shift needs the paired POS device of the request, so each cashier works on a device
    -- of their own; its id is in the request headers, as the API sets it from a device token.
    INSERT INTO public.devices (id, organization_id, branch_id, name)
    SELECT ('f3030000-0000-0000-8000-00000000002' || n)::uuid, ${SCHEMA}.id('org'), ${SCHEMA}.id('main'),
           'Proof POS ' || n FROM generate_series(1, ${CASHIERS}) n;
    CREATE FUNCTION ${SCHEMA}.sign_in_as(p_cashier integer) RETURNS void LANGUAGE sql AS $$
      SELECT set_config('request.jwt.claim.sub', 'f3030000-0000-0000-8000-00000000001' || p_cashier, true),
             set_config('app.org_id', '', true),
             set_config('request.headers', json_build_object('x-org-id', ${SCHEMA}.id('org'),
               'x-device-id', 'f3030000-0000-0000-8000-00000000002' || p_cashier)::text, true) $$;
    ${Array.from(
      { length: CASHIERS },
      (_, i) => `BEGIN; SELECT ${SCHEMA}.sign_in_as(${i + 1});
    SELECT public.open_shift(${SCHEMA}.id('main'), '0', 'test3-proof-shift-${i + 1}'); COMMIT;`,
    ).join('\n    ')}
    BEGIN; SELECT ${SCHEMA}.sign_in();
    INSERT INTO ${SCHEMA}.ids VALUES ('lamp', public.create_product('{"name_ar":"Proof lamp","sku":"T3P-LP","cash_price":"100"}'));
    SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL,
      jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 1)), 'test3-proof-chair-3');
    SELECT public.register_units(${SCHEMA}.id('phone'), ${SCHEMA}.id('main'), '3000.00', '["T3P-IMEI-2"]', NULL, 'test3-proof-unit-2');
    INSERT INTO ${SCHEMA}.ids SELECT 'unit2', id FROM public.units WHERE organization_id = ${SCHEMA}.id('org') AND serial = 'T3P-IMEI-2';
    COMMIT; TRUNCATE ${SCHEMA}.outcomes;

    -- One sale request as the API makes it: the cashier quotes the cart and sells it at that total.
    CREATE FUNCTION ${SCHEMA}.sale(p_kind text, p_cashier integer) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      v_key text := CASE WHEN p_kind = 'sale_same_key' THEN 'test3-proof-one-key' ELSE 'test3-proof-' || gen_random_uuid() END;
      v_chair jsonb := jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 1);
      v_lamp jsonb := jsonb_build_object('product_id', ${SCHEMA}.id('lamp'), 'quantity', 1);
      v_lines jsonb := CASE p_kind
        WHEN 'sale_unit' THEN jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('phone'), 'quantity', 1, 'unit_id', ${SCHEMA}.id('unit2')))
        WHEN 'sale_ab' THEN jsonb_build_array(v_chair, v_lamp)
        WHEN 'sale_ba' THEN jsonb_build_array(v_lamp, v_chair)
        ELSE jsonb_build_array(v_chair) END;
      v_sale jsonb; v_customer uuid; v_payments jsonb;
    BEGIN
      PERFORM ${SCHEMA}.sign_in_as(p_cashier);
      -- S02: the whole sale paid with the customer's store credit.
      IF p_kind = 'sale_credit' THEN
        v_lines := jsonb_build_array(v_lamp);
        v_customer := ${SCHEMA}.id('buyer');
        v_payments := jsonb_build_array(jsonb_build_object('method', 'store_credit',
          'amount', public.quote_sale(v_lines)->>'total'));
      END IF;
      BEGIN
        v_sale := public.post_sale(v_lines, public.quote_sale(v_lines)->>'total', v_key, v_customer, v_payments);
        INSERT INTO ${SCHEMA}.outcomes (kind, result, ref) VALUES (p_kind, 'done', (v_sale->>'id')::uuid);
      EXCEPTION WHEN others THEN
        INSERT INTO ${SCHEMA}.outcomes (kind, result, error) VALUES (p_kind, 'refused', SQLERRM);
      END;
    END $$;`);
  const saleScript = (kind) =>
    `\\set c random(1, ${CASHIERS})\nSELECT ${SCHEMA}.sale('${kind}', :c);\n`;
  const salesMade = () =>
    psql(`SELECT concat_ws('|', count(*), COALESCE(max(right(number, 6)::integer), 0), count(DISTINCT shift_id))
          FROM public.sales WHERE organization_id = ${SCHEMA}.id('org');`).split('|');

  // ---------------------------------------------------------------- F. the last chair, sold
  await round('F.', '/tmp/test3_sale_chair.sql', saleScript('sale_chair'));
  [done, refused, other, firstOther, backends] = outcomes('sale_chair', 'OUT_OF_STOCK');
  let [saleRows, lastNo] = salesMade();
  const partF = report([
    ['F. exactly one cashier sold the last chair', done === '1', done],
    [`F. the other ${CLIENTS - 1} got OUT_OF_STOCK`, Number(refused) === CLIENTS - 1, refused],
    ['F. no other errors (no deadlocks)', other === '0', `${other} ${firstOther}`],
    [
      'F. one sale; the refused ones took no number',
      saleRows === '1' && lastNo === '1',
      `${saleRows} sales, last number ${lastNo}`,
    ],
    ['F. the chair is at exactly 0, never below', level('chair') === '0', level('chair')],
    [
      'F. the requests came from many concurrent sessions',
      Number(backends) >= Math.min(CLIENTS, 10),
      `${backends} sessions`,
    ],
  ]);

  // ---------------------------------------------------------------- G. one IMEI unit, sold
  await round('G.', '/tmp/test3_sale_unit.sql', saleScript('sale_unit'));
  [done, refused, other, firstOther] = outcomes('sale_unit', 'UNIT_NOT_AVAILABLE,OUT_OF_STOCK');
  const [unit2Status, unit2Out] = psql(`
    SELECT concat_ws('|', (SELECT status FROM public.units WHERE id = ${SCHEMA}.id('unit2')),
      (SELECT count(*) FROM public.stock_movements WHERE unit_id = ${SCHEMA}.id('unit2') AND type = 'sale_out'));`).split(
    '|',
  );
  const partG = report([
    ['G. exactly one sale of the unit', done === '1', done],
    [
      `G. the other ${CLIENTS - 1} were refused (the unit is sold)`,
      Number(refused) === CLIENTS - 1,
      refused,
    ],
    ['G. no other errors', other === '0', `${other} ${firstOther}`],
    [
      'G. the unit is sold, by exactly one sale_out row',
      unit2Status === 'sold' && unit2Out === '1',
      `${unit2Status}, ${unit2Out} row`,
    ],
  ]);

  // ---------------------------------------------------------------- H. one key, many requests
  psql(`BEGIN; SELECT ${SCHEMA}.sign_in();
        SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL,
          jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 5)), 'test3-proof-chair-4');
        COMMIT;`);
  await round('H.', '/tmp/test3_sale_key.sql', saleScript('sale_same_key'));
  [done, refused, other, firstOther] = outcomes('sale_same_key', '-');
  const [answers, keySales, keyStock, keyCash, keyPayments] = psql(`
    SELECT concat_ws('|',
      (SELECT count(DISTINCT ref) FROM ${SCHEMA}.outcomes WHERE kind = 'sale_same_key'),
      (SELECT count(*) FROM public.sales WHERE organization_id = ${SCHEMA}.id('org') AND idempotency_key = 'test3-proof-one-key'),
      (SELECT count(*) FROM public.stock_movements m JOIN public.sales s ON s.id = m.source_id WHERE s.idempotency_key = 'test3-proof-one-key'),
      (SELECT count(*) FROM public.cash_movements m JOIN public.sales s ON s.id = m.source_id WHERE s.idempotency_key = 'test3-proof-one-key'),
      (SELECT count(*) FROM public.payment_allocations a JOIN public.sales s ON s.id = a.sale_id WHERE s.idempotency_key = 'test3-proof-one-key'));`).split(
    '|',
  );
  [saleRows, lastNo] = salesMade();
  const partH = report([
    [
      `H. all ${CLIENTS} requests got an answer, none refused`,
      Number(done) === CLIENTS && refused === '0' && other === '0',
      `${done} done, ${other} ${firstOther}`,
    ],
    ['H. all of them got the same sale', answers === '1', `${answers} distinct`],
    [
      'H. one sale, one stock movement, one cash movement, one payment',
      keySales === '1' && keyStock === '1' && keyCash === '1' && keyPayments === '1',
      `${keySales} / ${keyStock} / ${keyCash} / ${keyPayments}`,
    ],
    [
      'H. the repeats took no number: the sale is number 3',
      saleRows === '3' && lastNo === '3',
      `${saleRows} sales, last number ${lastNo}`,
    ],
    ['H. stock went down by 1 only (5 -> 4)', level('chair') === '4', level('chair')],
  ]);

  // ---------------------------------------------------------------- I. two-product carts in both orders
  psql(`BEGIN; SELECT ${SCHEMA}.sign_in();
        SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL, jsonb_build_array(
          jsonb_build_object('product_id', ${SCHEMA}.id('chair'), 'quantity', 6),
          jsonb_build_object('product_id', ${SCHEMA}.id('lamp'), 'quantity', 10)), 'test3-proof-carts');
        COMMIT;`);
  await round(
    'I.',
    '/tmp/test3_sale_carts.sql',
    `\\set c random(1, ${CASHIERS})\n\\set r random(1, 2)\nSELECT ${SCHEMA}.sale(CASE :r WHEN 1 THEN 'sale_ab' ELSE 'sale_ba' END, :c);\n`,
  );
  [done, refused, other, firstOther] = outcomes('sale_ab,sale_ba', 'OUT_OF_STOCK');
  const [orders, shiftsUsed] = psql(`
    SELECT concat_ws('|', (SELECT count(DISTINCT kind) FROM ${SCHEMA}.outcomes WHERE kind IN ('sale_ab', 'sale_ba')),
      (SELECT count(DISTINCT shift_id) FROM public.sales WHERE organization_id = ${SCHEMA}.id('org')));`).split(
    '|',
  );
  const partI = report([
    ['I. carts came in both product orders', orders === '2', `${orders} orders`],
    ['I. exactly 10 carts sold (10 chairs and 10 lamps were there)', done === '10', done],
    [`I. the other ${CLIENTS - 10} got OUT_OF_STOCK`, Number(refused) === CLIENTS - 10, refused],
    ['I. no deadlock and no other error', other === '0', `${other} ${firstOther}`],
    [
      'I. chairs and lamps are at exactly 0',
      level('chair') === '0' && level('lamp') === '0',
      `${level('chair')} / ${level('lamp')}`,
    ],
    ['I. the sales came from more than one shift', Number(shiftsUsed) > 1, `${shiftsUsed} shifts`],
  ]);
  const money = psql(`
    SELECT concat_ws(' / ',
      (SELECT sum(total) FROM public.sales WHERE organization_id = ${SCHEMA}.id('org')),
      (SELECT sum(a.amount) FROM public.payment_allocations a WHERE a.organization_id = ${SCHEMA}.id('org') AND a.sale_id IS NOT NULL),
      (SELECT sum(m.amount) FROM public.cash_movements m WHERE m.organization_id = ${SCHEMA}.id('org') AND m.type = 'sale'));`);
  const partMoney = report([
    [
      "E. the sales' totals = their payments = the drawers' sale movements",
      new Set(money.split(' / ')).size === 1,
      money,
    ],
  ]);
  // ---------------------------------------------------------------- J. store credit, spent once (S02)
  // A customer holds exactly one lamp's worth of store credit; every request sells a lamp and
  // pays it entirely with that credit. The balance row is locked while it is read: one wins.
  psql(`BEGIN; SELECT ${SCHEMA}.sign_in();
        SELECT public.post_stock_adjustment(${SCHEMA}.id('main'), 'found', NULL,
          jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('lamp'), 'quantity', 25)), 'test3-proof-lamps-2');
        INSERT INTO public.customers (organization_id, full_name)
          VALUES (${SCHEMA}.id('org'), 'Proof store credit buyer');
        INSERT INTO ${SCHEMA}.ids SELECT 'buyer', id FROM public.customers
          WHERE organization_id = ${SCHEMA}.id('org') AND full_name = 'Proof store credit buyer';
        COMMIT;
        BEGIN; SELECT ${SCHEMA}.sign_in_as(1);
        INSERT INTO public.store_credit_movements (organization_id, customer_id, amount, source_type, source_id, branch_id, business_date)
          SELECT ${SCHEMA}.id('org'), ${SCHEMA}.id('buyer'),
                 (public.quote_sale(jsonb_build_array(jsonb_build_object('product_id', ${SCHEMA}.id('lamp'), 'quantity', 1)))->>'total')::numeric,
                 'sales_return', gen_random_uuid(), ${SCHEMA}.id('main'), app.org_today(${SCHEMA}.id('org'));
        COMMIT; TRUNCATE ${SCHEMA}.outcomes;`);
  const credit = psql(
    `SELECT balance FROM public.store_credit_balances WHERE customer_id = ${SCHEMA}.id('buyer');`,
  );
  await round('J.', '/tmp/test3_sale_credit.sql', saleScript('sale_credit'));
  [done, refused, other, firstOther] = outcomes('sale_credit', 'INSUFFICIENT_STORE_CREDIT');
  const [creditBalance, creditMoves, creditPayments] = psql(`
    SELECT concat_ws('|',
      (SELECT balance FROM public.store_credit_balances WHERE customer_id = ${SCHEMA}.id('buyer')),
      (SELECT count(*) FROM public.store_credit_movements WHERE customer_id = ${SCHEMA}.id('buyer') AND amount < 0),
      (SELECT count(*) FROM public.payments WHERE customer_id = ${SCHEMA}.id('buyer') AND method = 'store_credit'));`).split(
    '|',
  );
  const partJ = report([
    ['J. exactly one sale was paid with the store credit', done === '1', done],
    [
      `J. the other ${CLIENTS - 1} got INSUFFICIENT_STORE_CREDIT`,
      Number(refused) === CLIENTS - 1,
      refused,
    ],
    ['J. no other errors (no deadlocks)', other === '0', `${other} ${firstOther}`],
    [
      'J. one credit movement and one payment; the credit was spent exactly',
      creditMoves === '1' && creditPayments === '1' && Number(credit) > 0,
      `${creditMoves} / ${creditPayments}, had ${credit}`,
    ],
    ['J. the balance is exactly 0.00, never below', Number(creditBalance) === 0, creditBalance],
  ]);

  // ---------------------------------------------------------------- E. reconciliation
  const [shopMismatches, allMismatches] = psql(`
    SELECT concat_ws('|', (SELECT count(*) FROM app.ledger_mismatches(${SCHEMA}.id('org'))),
                          (SELECT count(*) FROM app.ledger_mismatches()));`).split('|');
  const partE = report([
    [
      'E. the proof shop reconciles: every cache = its ledger',
      shopMismatches === '0',
      `${shopMismatches} mismatches`,
    ],
    ['E. the whole database reconciles', allMismatches === '0', `${allMismatches} mismatches`],
  ]);

  failed = !(
    partA &&
    partB &&
    partC &&
    partD &&
    partF &&
    partG &&
    partH &&
    partI &&
    partMoney &&
    partJ &&
    partE
  );
} catch (error) {
  console.error(`db:stock-cash: ${error.message}`);
  failed = true;
} finally {
  try {
    cleanUp();
  } catch (error) {
    console.error(`db:stock-cash: cleanup failed: ${error.message}`);
    failed = true;
  }
}

console.log(failed ? 'db:stock-cash: FAILED' : 'db:stock-cash: passed');
process.exit(failed ? 1 : 0);
