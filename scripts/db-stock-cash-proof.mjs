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
//   E. app.ledger_mismatches() finds nothing, for the shop and for the whole database.
// (Sales are S01, Sprint 4; the sale race on the ledger itself is db:ledger, F10.)
import { pgbench, processed, psql, removeProofShop, report, writeFile } from './db-proof-lib.mjs';

const CLIENTS = Number(process.env.TEST3_CLIENTS ?? 20);
const SLUG = 'test3-proof';
const SCHEMA = 'test3_proof';
const ADMIN = 'f0000000-0000-0000-0000-000000000001'; // the seeded platform admin
const OWNER = 'f3030000-0000-0000-8000-000000000001';
const OWNER_EMAIL = 'test3-proof-owner@example.com';
const TOKEN = 'f'.repeat(64);

/** Removes what an earlier (interrupted) run left behind. */
function cleanUp() {
  const org = psql(`SELECT id FROM public.organizations WHERE tenant_slug = '${SLUG}';`);
  if (org) removeProofShop(org, SCHEMA);
  psql(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE; DELETE FROM auth.users WHERE id = '${OWNER}';`);
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

  failed = !(partA && partB && partC && partD && partE);
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
