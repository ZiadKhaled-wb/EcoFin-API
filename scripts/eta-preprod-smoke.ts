// T02 (D67): the pre-production smoke test of the ETA e-receipt integration ("done when": test
// receipts are accepted by the ETA pre-production system). Run: npm run eta:preprod-smoke
//
// It builds two chained test receipts with the real builder, submits them to the ETA
// PRE-PRODUCTION system, polls until each is Valid or Invalid, prints the UUIDs, statuses and
// any errors, then sends the same submission again to show the ETA refuses a duplicate and that
// the lookup by UUID finds the receipts (the path the worker takes before any resend).
//
// It runs only when every ETA_TEST_* variable below is set (in the environment, never in a
// committed file); otherwise it prints "skipped: no pre-production credentials" and exits 0.
// It never prints a secret, a key or a token. Exit code 1 when a receipt is not accepted.
//
// Pre-production uses the ETA's own root certificate: start Node with
// NODE_EXTRA_CA_CERTS=<path to preprod-root-ca.crt> (docs/eta/SETUP.md). Never turn TLS checks off.
//
// Optional: ETA_TEST_PREVIOUS_UUID (the last UUID this POS issued in pre-production; empty for
// its very first receipt), ETA_TEST_ITEM_TYPE (EGS or GS1, default EGS), ETA_TEST_COMPANY_NAME,
// ETA_TEST_GOVERNORATE, ETA_TEST_CITY, ETA_TEST_STREET, ETA_TEST_BUILDING_NUMBER.
import 'dotenv/config';
import { buildReceipt, type Receipt, type ReceiptSource } from '../src/eta/build-receipt';
import { EtaClient, EtaError, type EtaSession } from '../src/eta/client';
import { etaHosts } from '../src/eta/config';
import { toJson } from '../src/eta/serialize';
import { noSignature } from '../src/eta/signer';
import { createLogger } from '../src/utils/logger';

const REQUIRED = [
  'ETA_TEST_CLIENT_ID',
  'ETA_TEST_CLIENT_SECRET',
  'ETA_TEST_POS_SERIAL',
  'ETA_TEST_POS_OS_VERSION',
  'ETA_TEST_POS_MODEL_FRAMEWORK',
  'ETA_TEST_PRESHARED_KEY',
  'ETA_TEST_RIN',
  'ETA_TEST_ACTIVITY_CODE',
  'ETA_TEST_BRANCH_CODE',
  'ETA_TEST_ITEM_CODE',
] as const;

/** The production hosts the SDK documents: this script never talks to them. */
const PRODUCTION_HOSTS = ['id.eta.gov.eg', 'api.invoicing.eta.gov.eg', 'invoicing.eta.gov.eg'];

const env = (name: string, fallback = ''): string => (process.env[name] ?? '').trim() || fallback;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const utcSeconds = (date: Date) => date.toISOString().slice(0, 19) + 'Z';

async function main(): Promise<number> {
  if (REQUIRED.some((name) => env(name) === '')) {
    console.log('skipped: no pre-production credentials');
    return 0;
  }

  const hosts = etaHosts({
    ETA_PREPROD_ID_URL: env('ETA_PREPROD_ID_URL', 'https://id.preprod.eta.gov.eg'),
    ETA_PREPROD_API_URL: env('ETA_PREPROD_API_URL', 'https://api.preprod.invoicing.eta.gov.eg'),
    ETA_PREPROD_PORTAL_URL: env('ETA_PREPROD_PORTAL_URL', 'https://preprod.invoicing.eta.gov.eg'),
    // Never used here: the session below is 'preprod'.
    ETA_PROD_ID_URL: 'https://id.eta.gov.eg',
    ETA_PROD_API_URL: 'https://api.invoicing.eta.gov.eg',
    ETA_PROD_PORTAL_URL: 'https://invoicing.eta.gov.eg',
  });
  for (const url of [hosts.preprod.idUrl, hosts.preprod.apiUrl]) {
    if (PRODUCTION_HOSTS.includes(new URL(url).host)) {
      console.error(
        `refused: ${new URL(url).host} is a production host; this is a pre-production test`,
      );
      return 1;
    }
  }

  const session: EtaSession = {
    environment: 'preprod',
    deviceId: 'smoke',
    credentials: {
      clientId: env('ETA_TEST_CLIENT_ID'),
      clientSecret: env('ETA_TEST_CLIENT_SECRET'),
      posSerial: env('ETA_TEST_POS_SERIAL'),
      posOsVersion: env('ETA_TEST_POS_OS_VERSION'),
      posModelFramework: env('ETA_TEST_POS_MODEL_FRAMEWORK'),
      presharedKey: env('ETA_TEST_PRESHARED_KEY'),
    },
  };
  const client = new EtaClient({ hosts, logger: createLogger({ level: 'silent' }) });

  // Two sales as the POS stores them: 1 140.00 with VAT, the second with a 114.00 discount.
  const stamp = Date.now();
  const now = new Date();
  const source = (n: number, discount: string, tax: string, total: string): ReceiptSource => ({
    sale: {
      number: `SMOKE-${stamp}-${n}`,
      issued_at: utcSeconds(new Date(now.getTime() - (3 - n) * 1000)),
      prices_include_vat: true,
      total,
    },
    lines: [
      {
        line_no: 1,
        quantity: 1,
        unit_price: '1140.00',
        discount_amount: discount,
        tax_rate: '14.00',
        tax_amount: tax,
        line_total: total,
        sku: 'SMOKE-ITEM',
        name: 'Smoke test item',
        eta_item_code: env('ETA_TEST_ITEM_CODE'),
        eta_item_type: env('ETA_TEST_ITEM_TYPE', 'EGS'),
        eta_tax_type: 'T1',
        eta_subtype: 'V009',
      },
    ],
    payments: [{ method: 'cash', amount: total }],
    customer: null,
    seller: {
      rin: env('ETA_TEST_RIN'),
      name: env('ETA_TEST_COMPANY_NAME', 'EcoTech Pro smoke test'),
      activity_code: env('ETA_TEST_ACTIVITY_CODE'),
      branch_code: env('ETA_TEST_BRANCH_CODE'),
      governorate: env('ETA_TEST_GOVERNORATE', 'Cairo'),
      city: env('ETA_TEST_CITY', 'Nasr City'),
      street: env('ETA_TEST_STREET', 'Test street'),
      building_number: env('ETA_TEST_BUILDING_NUMBER', '1'),
    },
    device: { serial: env('ETA_TEST_POS_SERIAL'), status: 'active', is_active: true },
  });
  const first = buildReceipt(source(1, '0.00', '140.00', '1140.00'), env('ETA_TEST_PREVIOUS_UUID'));
  const second = buildReceipt(source(2, '114.00', '126.00', '1026.00'), first.header.uuid);
  const receipts: Receipt[] = [first, second];
  const payload = receipts.map((receipt) => toJson(receipt));
  console.log(`pre-production: ${new URL(hosts.preprod.apiUrl).host}`);
  for (const receipt of receipts) {
    console.log(
      `built ${receipt.header.receiptNumber}: uuid ${receipt.header.uuid}, previous ${receipt.header.previousUUID || '(none)'}, total ${receipt.totalAmount.text}`,
    );
  }

  const accepted = new Set<string>();
  let ok = true;
  const submission = await client.submit(session, payload, await noSignature.sign(payload));
  console.log(`submitted: submission ${submission.submissionUuid ?? '(none)'}`);
  for (const doc of submission.rejected) {
    ok = false;
    console.log(`REJECTED at submission: ${doc.receiptNumber ?? doc.uuid ?? '?'}: ${doc.error}`);
  }
  for (const doc of submission.accepted) accepted.add(doc.uuid);

  if (submission.submissionUuid && accepted.size > 0) {
    const waiting = new Set(accepted);
    for (let poll = 0; poll < 36 && waiting.size > 0; poll++) {
      await sleep(5000);
      const details = await client.submissionDetails(session, submission.submissionUuid);
      for (const doc of details.receipts) {
        if (!waiting.has(doc.uuid) || (doc.status !== 'valid' && doc.status !== 'invalid'))
          continue;
        waiting.delete(doc.uuid);
        if (doc.status === 'valid')
          console.log(`VALID   ${doc.uuid} (long id ${doc.longId ?? '?'})`);
        else {
          ok = false;
          console.log(`INVALID ${doc.uuid}: ${doc.error ?? 'no reason given'}`);
        }
      }
    }
    for (const uuid of waiting) {
      ok = false;
      console.log(`NO ANSWER after 3 minutes: ${uuid}`);
    }
  }

  // The same submission again: the ETA must refuse it as a duplicate, and the lookup by UUID
  // (what the worker does before it would ever resend) must find the receipts.
  try {
    const again = await client.submit(session, payload, await noSignature.sign(payload));
    console.log(
      `duplicate check: the ETA TOOK the same submission again (submission ${again.submissionUuid ?? '?'}). ` +
        'The worker never resends without a lookup, but note this in docs/eta/ERECEIPT_SPEC.md.',
    );
  } catch (err) {
    if (!(err instanceof EtaError)) throw err;
    console.log(
      err.kind === 'duplicate'
        ? `duplicate check: refused as DuplicateSubmission (Retry-After ${err.retryAfterSeconds ?? '?'} s)`
        : `duplicate check: refused (${err.kind}, HTTP ${err.status ?? '?'}): ${err.message}`,
    );
  }
  for (const receipt of receipts) {
    const found = await client.lookup(session, receipt.header.uuid);
    console.log(
      found
        ? `lookup ${receipt.header.uuid}: found, ${found.status}, submission ${found.submissionUuid ?? '?'}`
        : `lookup ${receipt.header.uuid}: not found`,
    );
    if (accepted.has(receipt.header.uuid) && !found) ok = false;
  }

  console.log(
    `last UUID of this POS (ETA_TEST_PREVIOUS_UUID for the next run): ${second.header.uuid}`,
  );
  console.log(ok ? 'RESULT: accepted' : 'RESULT: not accepted (see above)');
  return ok ? 0 : 1;
}

main()
  .then((exitCode) => {
    process.exitCode = exitCode;
  })
  .catch((err: unknown) => {
    // An EtaError's message is already masked; anything else prints its name and message only.
    if (err instanceof EtaError) {
      console.error(`RESULT: failed (${err.kind}, HTTP ${err.status ?? 'none'}): ${err.message}`);
      if (err.kind === 'unknown') {
        console.error(
          'If this is a certificate error, start Node with NODE_EXTRA_CA_CERTS=<preprod-root-ca.crt> (docs/eta/SETUP.md).',
        );
      }
    } else {
      console.error(
        `RESULT: failed: ${err instanceof Error ? `${err.name}: ${err.message}` : 'unknown error'}`,
      );
    }
    process.exitCode = 1;
  });
