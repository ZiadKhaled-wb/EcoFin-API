# ETA e-receipts: setting a shop up

How a shop is connected to the Egyptian Tax Authority (ETA) e-receipt system, first on the ETA's
test system (pre-production), then on the real one. The format and the rules are in
[`ERECEIPT_SPEC.md`](ERECEIPT_SPEC.md).

Do the steps in order. Do not switch a shop to production before step 5 passes.

## 1. On the ETA portal: the shop's B2C access

Pre-production portal: <https://preprod.invoicing.eta.gov.eg> (profile: <https://profile.preprod.eta.gov.eg>).
Production portal: <https://invoicing.eta.gov.eg> (profile: <https://profile.eta.gov.eg>).

1. The shop's taxpayer profile must have the **B2C tag**. Without it the ETA refuses every receipt.
   Ask the ETA for it if the profile doesn't show it.
2. In the profile, register an **ERP system** for the shop and copy its **client ID** and
   **client secret**. The secret is shown once.
3. Note the shop's **registration number** (RIN, 9 digits), one of its **activity codes**, and the
   **branch ID** of each branch as the portal shows it (the ID, not the branch name).
4. Each product sold needs an **item code** the ETA knows: an EGS code registered for the shop, or
   a GS1 code.

## 2. On the ETA portal: each POS device

For every till that will sell:

1. Register the **POS device** under the shop's profile, linked to its branch.
2. Copy its **serial number**, **OS version**, **model framework** and **pre-shared key**. They
   are the four values the device logs in with.
3. Wait until the ETA shows the device as active.

## 3. In EcoTech Pro: the settings

Sign in as the owner (or a user with `org.settings_manage`, `branch.manage`, `device.manage`).

1. **Settings → Shop profile:** the tax registration number (the RIN) and the legal name.
2. **Settings → Branches:** for each branch its address, city, governorate, **building number**
   and **ETA branch code** (the branch ID from step 1.3).
3. **Products:** each product's **ETA item code** and type (EGS or GS1).
4. **Settings → POS devices:** for each device its serial, OS version, model framework,
   pre-shared key and status **Active**. The key is stored encrypted and is never shown again.
5. **Settings → ETA e-receipts:** system **Pre-production**, the client ID, the client secret, the
   activity code; turn **Send receipts to the ETA** on. The secret is stored encrypted and is
   never shown again.
6. On the same page, **Test connection** with a device. "Connected" means the ETA accepted the
   client ID, the secret and that device's four values. Otherwise the ETA's reason is shown, for
   example `invalid_presharedkey`.

7. **Create each POS device and pair it on its computer** (O03). On **Settings → POS devices**,
   **Add device** (a name and its branch), then **Pair**: the page shows an 8-character code for
   15 minutes. On the POS computer, a signed-in employee opens **Pair this computer** (the
   account menu, or the shift screen) and types the code. The computer is that device from then
   on; its name shows in the header. Do steps 4 and 6 for the device once it exists.

A cashier sells on a POS device by opening their shift on its computer: a shift can only be
opened from a paired computer, in the device's branch, and every sale of the shift carries that
device. A device that is not Active with a serial at the ETA still blocks its receipts
(`BLOCKED:NO_DEVICE`, step 4). **Unpair** or **Turn off** on the devices page stops a lost or
replaced computer on its next request.

## 4. What a blocked receipt means

A receipt that can't be built is not sent. It waits, with a reason, until the data is fixed and
it is retried (`POST /api/eta/submissions/:id/retry`; the screen is T03's).

| Reason | Fix |
| --- | --- |
| `BLOCKED:NO_DEVICE` | The sale had no POS, or the POS is not Active with a serial (step 3.4) |
| `BLOCKED:ITEM_CODE` | A product on the sale has no ETA item code or type (step 3.3) |
| `BLOCKED:SELLER_DATA` | The RIN (9 digits), the company name, the activity code, the branch code or part of the branch address is missing (steps 3.1, 3.2, 3.5) |
| `BLOCKED:BUYER_ID` | A sale of 150,000 EGP or more needs the customer's name and national ID; a business customer needs its 9-digit tax number |

The ETA takes a receipt for 24 hours after the sale. A receipt still waiting after 20 hours
raises an alert (`eta.failed`, reason `deadline`).

## 5. The pre-production smoke test

Run it on a machine that can reach the ETA, from `EcoFin-API`. It sends two chained test
receipts to the ETA **pre-production** system and prints what the ETA answered.

1. Download the pre-production root certificate
   (<https://sdk.invoicing.eta.gov.eg/files/preprod-root-ca.crt>) and point Node at it. Never
   install it on a production server, and never turn certificate checking off.
2. Set the variables in the shell. Never write them in a file that is committed.

   ```bash
   export NODE_EXTRA_CA_CERTS=/path/to/preprod-root-ca.crt
   export ETA_TEST_CLIENT_ID=...            # step 1.2
   export ETA_TEST_CLIENT_SECRET=...        # step 1.2
   export ETA_TEST_POS_SERIAL=...           # step 2.2
   export ETA_TEST_POS_OS_VERSION=...       # step 2.2
   export ETA_TEST_POS_MODEL_FRAMEWORK=...  # step 2.2
   export ETA_TEST_PRESHARED_KEY=...        # step 2.2
   export ETA_TEST_RIN=...                  # step 1.3
   export ETA_TEST_ACTIVITY_CODE=...        # step 1.3
   export ETA_TEST_BRANCH_CODE=...          # step 1.3
   export ETA_TEST_ITEM_CODE=...            # step 1.4 (ETA_TEST_ITEM_TYPE=GS1 for a GS1 code)
   npm run eta:preprod-smoke
   ```

   Optional: `ETA_TEST_COMPANY_NAME`, `ETA_TEST_GOVERNORATE`, `ETA_TEST_CITY`, `ETA_TEST_STREET`,
   `ETA_TEST_BUILDING_NUMBER`, and `ETA_TEST_PREVIOUS_UUID` (the last line of the previous run:
   a POS that already issued receipts continues its chain from there).
3. Read the result.

   | Output | Meaning |
   | --- | --- |
   | `skipped: no pre-production credentials` | A variable of the list is missing |
   | `VALID <uuid>` twice and `RESULT: accepted` | Done: the ETA accepts our receipts |
   | `REJECTED at submission` or `INVALID <uuid>: <reason>` | The ETA refused one. Fix what the reason names. If it is about the format, a calculation or the signature, update [`ERECEIPT_SPEC.md`](ERECEIPT_SPEC.md) first, then the code |
   | `RESULT: failed (auth ...)` | The client ID, the secret or one of the POS values is wrong |
   | `RESULT: failed (unknown ...)` | The ETA was not reached: the network, or the certificate of step 5.1 |
   | `duplicate check: refused as DuplicateSubmission` | Expected: the ETA refuses the same submission twice |

   The script never prints a secret, a key or a token.

## 6. Going to production

Only after step 5 printed `RESULT: accepted`:

1. Repeat steps 1 and 2 on the **production** portal. Production has its own client ID, client
   secret and POS values.
2. Wait until every receipt of the shop is accepted or rejected. The system can't be changed
   while a receipt is on its way (`ETA_ENV_BUSY`).
3. **Settings → ETA e-receipts:** system **Production**, the production client ID and secret.
   **Settings → POS devices:** each device's production serial and key.
4. **Test connection** again.

From then on receipts are real. A receipt made for one system is never sent to the other.

## For the server operator

- The ETA hosts come from `ETA_PREPROD_*` and `ETA_PROD_*` (`.env.example`). The defaults are the
  hosts the SDK documents; change them only if the ETA does. The server refuses to start when a
  production and a pre-production variable name the same host.
- A server that talks to pre-production needs `NODE_EXTRA_CA_CERTS` as in step 5.1.
- The background jobs (`JOBS_ENABLED=true`) send the receipts: `eta.prepare`, `eta.submit`,
  `eta.poll`. With the jobs off, receipts are built with each sale but never sent.
- Alerts arrive through the error tracker (Sentry) with the tag `problem: eta.failed` and a
  `reason`: `deadline`, `rejected`, `invalid`, `auth`, `poll_timeout` or a `BLOCKED:` code.
