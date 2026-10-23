# ETA e-receipt spec (T02, EC-90)

What EcoTech Pro sends to the Egyptian Tax Authority for a consumer (B2C) receipt, taken from the
official SDK at `https://sdk.invoicing.eta.gov.eg`. Read on 2026-10-12; the newest release note on
the site then was "Aug 2023 Release" (22-08-2023).

**When this file and the SDK disagree, the SDK wins.** Update this file, then the code.

Nothing here has been checked against the pre-production system yet. Items that only a real
submission can settle are marked **(unverified)**; `npm run eta:preprod-smoke` settles them
(see `SETUP.md`).

## 1. Hosts

Source: <https://sdk.invoicing.eta.gov.eg/faq/#how-to-set-up-environment-to-access-test-apis-and-test-portals>
and the two Postman environment files linked from that page.

| | Pre-production | Production | Env variable |
|---|---|---|---|
| Identity service | `https://id.preprod.eta.gov.eg` | `https://id.eta.gov.eg` | `ETA_PREPROD_ID_URL` / `ETA_PROD_ID_URL` |
| System API | `https://api.preprod.invoicing.eta.gov.eg` | `https://api.invoicing.eta.gov.eg` | `ETA_PREPROD_API_URL` / `ETA_PROD_API_URL` |
| Invoicing portal (QR) | `https://preprod.invoicing.eta.gov.eg` | `https://invoicing.eta.gov.eg` | `ETA_PREPROD_PORTAL_URL` / `ETA_PROD_PORTAL_URL` |

- The token call goes to the identity service, every other call to the system API.
- Pre-production uses an internally issued root certificate
  (<https://sdk.invoicing.eta.gov.eg/files/preprod-root-ca.crt>). Node must trust it to reach
  pre-production: start the process with `NODE_EXTRA_CA_CERTS=<path to the file>`. Never install
  it on a production machine and never turn certificate checking off.
- The host set is chosen by `eta_settings.environment`; a `prod` shop is never sent to a preprod
  host or the reverse.

## 2. Token (Authenticate POS)

Source: <https://sdk.invoicing.eta.gov.eg/ereceiptapi/01-authenticate-pos/>

`POST {identity}/connect/token`, `Content-Type: application/x-www-form-urlencoded`.

| Where | Name | Limit | Value |
|---|---|---|---|
| Header | `posserial` | String (100) | the device's ETA serial |
| Header | `pososversion` | String (50) | the device's OS version |
| Header | `posmodelframework` | String (10) | the device's model framework |
| Header | `presharedkey` | String (200) | the device's pre-shared key |
| Body | `grant_type` | | `client_credentials` |
| Body | `client_id` | String (100) | the shop's client id |
| Body | `client_secret` | String (100) | the shop's client secret |

- 200: `access_token` (JWT), `token_type` (`Bearer`), `expires_in` (seconds; 3600), `scope`.
- 400: `{ "error": "<code>" }` with `unauthorized_client`, `invalid_posserial`,
  `invalid_pososversion`, `invalid_posmodelframework`, `invalid_presharedkey`,
  `unsupported_grant_type`, `invalid_scope`, `invalid_request` or `invalid_clientsecret`.
- The token lasts one hour. Get a new one before it expires; asking for a token on every call is
  listed as an anti-pattern (<https://sdk.invoicing.eta.gov.eg/integrationpractices/>). We cache
  one per device until 60 s before expiry.
- Only taxpayers with the B2C tag can submit receipts.
- Later calls send `Authorization: Bearer <token>`
  (<https://sdk.invoicing.eta.gov.eg/standard-header-parameters/>).

## 3. Submit

Source: <https://sdk.invoicing.eta.gov.eg/ereceiptapi/02-submit-receipt/>

`POST {api}/api/v1/receiptsubmissions`, `Content-Type: application/json`.

Body: `{ "receipts": [ <receipt>, ... ], "signatures": [ ... ] }`.

**202** (received, validation continues in the background):

| Field | Meaning |
|---|---|
| `submissionUUID` | String (30); used to poll |
| `acceptedDocuments[]` | `uuid`, `longId` (String 200), `receiptNumber` |
| `rejectedDocuments[]` | `receiptNumber`, `uuid`, `error { message, target, propertyPath, details[] }` |

Rejected-document sample: <https://sdk.invoicing.eta.gov.eg/files/rejecteddocument.json>
(`error.details[]` items carry `code`, `message`, `target`, `propertyPath`).

**Errors** (standard shape `{ "error": { code, message, target, details[] } }`,
<https://sdk.invoicing.eta.gov.eg/standard-error-response/>):

| Status | Code | Meaning |
|---|---|---|
| 400 | `BadStructure` | the body is not a valid submission |
| 400 | `MaximumSizeExceeded` | too big; send smaller submissions |
| 403 | `IncorrectSubmitter` | submitting for another taxpayer |
| 422 | `DuplicateSubmission` | an identical payload from this taxpayer in the last 10 minutes; the `Retry-After` header gives the wait in seconds |
| 429 | `TooManyRequests` | wait longer than `Retry-After` (<https://sdk.invoicing.eta.gov.eg/apigovernance/>) |
| 503 | `ServiceUnavailable` | overloaded; retry after 1 to 3 s |

**Limits** (<https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#limitations-on-receipt-submission>):

- 1 to 500 receipts and at most 1.5 MB per submission; at most 300 lines per receipt.
- Every receipt in a POS submission must come from the same POS.
- `receiptNumber` is unique per branch within a submission.
- We send one device's receipts per submission, 50 at most, and split a batch that would pass
  1.4 MB.

**Resending** (<https://sdk.invoicing.eta.gov.eg/integrationpractices/>): a submission is resent
only after an error from the submit call. After any 20x it is never resent.

**Signatures.** The page says "At least signature of the Issuer must be present"
(`{ signatureType: "I", value: <Base64 CAdES-BES> }`), and also: "The function to perform
signature validation will not be deployed at this point until a decision is provided by ETA".
The SDK's own batch sample (<https://sdk.invoicing.eta.gov.eg/files/BatchReceipt.json>) sends
`"signatures": [ ]`; its Postman sample "2.1. Submit Receipt" leaves the key out. We send
`"signatures": []` **(unverified)**. If pre-production refuses unsigned submissions, CAdES-BES
(<https://sdk.invoicing.eta.gov.eg/receipt-batch-signature-creation/>) has to be built behind the
`ReceiptSigner` interface: it signs the SHA-256 of the serialized **whole batch**.

## 4. Submission details (poll)

Source: <https://sdk.invoicing.eta.gov.eg/ereceiptapi/06-get-receipt-submission/>

`GET {api}/api/v1/receiptsubmissions/{submissionUuid}/details?PageNo=1&PageSize=<n>`

- `status`: `InProgress`, `Valid` or `Invalid` (the whole submission).
- `receipts[]` (paged): `uuid`, `receiptNumber`, `longId`, `status` (`Valid`, `Invalid`,
  `Cancelled`), `errors[]`.
- `errors[]` items: `stepId`, `stepName`, `error { propertyPath, errorCode, error, errorAr, innerError }`.
- `metadata`: `totalPages`, `totalCount`, `currentPageNo`.
- We ask for a page as large as the batch (50) and read every page.

Polling this endpoint is the SDK's supported way to learn the result; asking for each receipt one
by one is listed as an anti-pattern.

## 5. Receipt lookup by UUID

Source: <https://sdk.invoicing.eta.gov.eg/ereceiptapi/04-get-receipt/>

`GET {api}/api/v1/receipts/{uuid}/raw`

- 200: `submissionUUID`, `dateTimeReceived`, `receipt { uuid, longId, status, statusReason, ... }`.
- 404 `NotFound`: the ETA has no such receipt.
- The issuer can read a receipt in received and cancelled status.
- Limit: 2 calls per second per POS.
- Used only after an unknown submit outcome (timeout, network error, 5xx) or a 422
  `DuplicateSubmission`: found means it was received, so the row moves to `submitted` with that
  `submissionUUID` and is polled; not found means it may be submitted again.

`GET {api}/api/v1/receipts/{uuid}/details` returns the same receipt with validation results
(<https://sdk.invoicing.eta.gov.eg/ereceiptapi/03-get-receipt-details/>); we don't need it.

## 6. Receipt v1.2: the fields we fill

Source: <https://sdk.invoicing.eta.gov.eg/documents/receipt-v1-2/>. Properties are written in
exactly this order (the order is part of the UUID, section 8).

| Field | Rule in the SDK | Our value |
|---|---|---|
| `header.dateTimeIssued` | mandatory, UTC, not in the future | `sales.issued_at`, cut to whole seconds: `2026-10-12T09:15:02Z` |
| `header.receiptNumber` | mandatory, String (50) | `sales.number` |
| `header.uuid` | mandatory, section 9 | computed |
| `header.previousUUID` | mandatory; `""` only for the first receipt of a POS | the device's last UUID, or `""` |
| `header.referenceOldUUID` | optional | `""` (the SDK samples send it empty) |
| `header.currency` | mandatory | `EGP` |
| `header.exchangeRate` | needed only when not EGP | `0` (the SDK samples send 0 for EGP) |
| `documentType.receiptType` | must be `s` | `s` |
| `documentType.typeVersion` | must be `1.2` | `1.2` |
| `seller.rin` | mandatory, 9 digits | `organizations.tax_registration_no` |
| `seller.companyTradeName` | mandatory, String (200) | `organizations.legal_name`, else `name` |
| `seller.branchCode` | mandatory, the branch ID from the taxpayer profile | `branches.eta_branch_code` |
| `seller.branchAddress.country` | mandatory | `EG` |
| `seller.branchAddress.governate` | mandatory, String (100) | `branches.governorate` |
| `seller.branchAddress.regionCity` | mandatory, String (100) | `branches.city` |
| `seller.branchAddress.street` | mandatory, String (200) | `branches.address` |
| `seller.branchAddress.buildingNumber` | mandatory, String (100) | `branches.building_number` |
| `seller.deviceSerialNumber` | mandatory, String (100) | `devices.eta_serial` |
| `seller.activityCode` | mandatory, String (10) | `eta_settings.activity_code` |
| `buyer.type` | mandatory: `B`, `P` or `F` | section 7 |
| `buyer.id` | section 7 | section 7 |
| `buyer.name` | section 7, String (100) | section 7 |
| `itemData[].internalCode` | mandatory, String (50) | `products.sku` |
| `itemData[].description` | mandatory, String (500) | `products.name_ar` |
| `itemData[].itemType` | mandatory: `EGS` or `GS1` | `products.eta_item_type` |
| `itemData[].itemCode` | mandatory, String (100) | `products.eta_item_code` |
| `itemData[].unitType` | mandatory, a unit code | `EA` (section 10) |
| `itemData[].quantity` | mandatory, > 0 | `sale_lines.quantity` |
| `itemData[].unitPrice` | mandatory, >= 0, up to 5 decimals | section 11 |
| `itemData[].netSale` | mandatory | section 11 |
| `itemData[].totalSale` | mandatory | section 11 |
| `itemData[].total` | mandatory | `sale_lines.line_total` |
| `itemData[].commercialDiscountData[]` | optional: `amount`, `description` (String 50) | one entry when the line has a discount |
| `itemData[].taxableItems[]` | `taxType`, `amount`, `subType`, `rate` | one T1 entry, section 10 |
| `totalSales` | mandatory, sum of `totalSale` | sum |
| `totalCommercialDiscount` | optional, sum of the commercial discounts | sum |
| `totalItemsDiscount` | optional | `0` |
| `netAmount` | mandatory, sum of `netSale` | sum |
| `feesAmount` | optional, zero only | `0` |
| `totalAmount` | mandatory | `sales.total` |
| `taxTotals[]` | `taxType`, `amount` | one T1 entry: the sum of the lines' T1 |
| `paymentMethod` | mandatory | section 10 |
| `adjustment` | optional, zero only | `0` |

Not sent (all optional): `header.sOrderNameCode`, `orderdeliveryMode`, `grossWeight`,
`netWeight`; `seller.syndicateLicenseNumber`; the branch address's `postalCode`, `floor`, `room`,
`landmark`, `additionalInformation`; `buyer.mobileNumber`, `buyer.paymentNumber`;
`itemData[].itemDiscountData`, `additionalCommercialDiscount`, `additionalItemDiscount`,
`valueDifference`; `extraReceiptDiscountData`; `contractor`; `beneficiary`.

**Receipt type.** The document page says `receiptType` "must be 's'" and the poll call lists the
codes as `s` and `r`; the SDK's Postman sample sends `S`. We follow the document page. The SDK
also defines sector receipts (for example Retail Receipt v1.2, `SR`) and checks "allowed receipt
types for taxpayer as per activity code". T02 sends the general Receipt `s` **(unverified for the
shop's activity code)**.

## 7. Buyer

Sources: <https://sdk.invoicing.eta.gov.eg/documents/receipt-v1-2/#buyer>,
<https://sdk.invoicing.eta.gov.eg/main-calculations/>,
<https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#national-id-validator>

| `type` | Meaning | `id` | `name` |
|---|---|---|---|
| `P` | natural person | national ID, 14 digits. Needed when `totalAmount` >= 150,000 EGP | needed when `totalAmount` >= 150,000 EGP |
| `B` | business in Egypt | RIN, 9 digits, always needed, and not the seller's own RIN | always needed |
| `F` | foreigner | any foreigner ID, optional | optional |

What we send:

| Sale | Buyer |
|---|---|
| no customer (walk-in), total below 150,000 | `{ type: "P" }` |
| a person, total below 150,000 | `{ type: "P", name }` (the national ID is not sent when it isn't needed) |
| a person, total >= 150,000 | `{ type: "P", id: national ID, name }`; without a 14-digit national ID or without a customer: `BLOCKED:BUYER_ID` |
| a business customer (`is_business`) | `{ type: "B", id: tax_registration_no, name }`; an RIN that isn't 9 digits or equals the seller's: `BLOCKED:BUYER_ID` |

`F` is not used: customers have no foreigner flag.

## 8. Serialization

Source: <https://sdk.invoicing.eta.gov.eg/document-serialization-approach/>

1. Walk the document from its root object, properties in document order.
2. A property name is written in upper case, in double quotes.
3. A simple value is written in double quotes, **exactly as it is written in the document**:
   `10.50` gives `"10.50"`, never `"10.5"`. The empty string gives `""`.
4. An object value is serialized the same way (its properties, in order).
5. An array: the property name is written **once for the array and once more before every
   element**. Two taxable items give `"TAXABLEITEMS""TAXABLEITEMS"<item 1>"TAXABLEITEMS"<item 2>`.
6. Everything is joined with no separator.
7. The result is read as UTF-8 before hashing.

The SDK's pseudo-code:

```
function string Serialize(documentStructure)
    if documentStructure is simple value type
        return """ + documentStructure.value + """
    end if
    var serializedString = ""
    foreach element in the structure:
        if element is not array type
            serializeString.Append (""" + element.name.uppercase + """)
            serializeString.Append ( Serialize(element.value) )
        end if
        if element is of array type
            serializeString.Append (""" + element.name.uppercase + """)
            foreach array element in element:
                serializeString.Append (""" + element.name.uppercase + """)
                serializeString.Append ( Serialize(arrayelement.value) )
            end foreach
        end if
    end foreach
    return serializedString
end function
```

**Worked example (the golden test).** Input
<https://sdk.invoicing.eta.gov.eg/files/one-doc.json>, expected output
<https://sdk.invoicing.eta.gov.eg/files/one-doc-serialized.json.txt>. It is an invoice, not a
receipt; the algorithm is the same. Its start:

```
"ISSUER""ADDRESS""BRANCHID""1""COUNTRY""EG""GOVERNATE""Cairo"...
```

and an array with literal number text:

```
"TAXABLEITEMS""TAXABLEITEMS""TAXTYPE""T1""AMOUNT""272.07""SUBTYPE""T1""RATE""14.00""TAXABLEITEMS""TAXTYPE""T2""AMOUNT""208.22""SUBTYPE""T2""RATE""12"
```

**What rule 3 means for our code.** The number text in the JSON we send must be the text we
hashed. So a receipt is never built with JS numbers and never passed through `JSON.stringify`:
decimals are strings from the F12 helpers, written as bare JSON numbers by our own writer, and
the exact JSON text of a prepared receipt is stored (`fiscal_submissions.payload.receipt_json`)
and sent unchanged: the submission body is put together from those texts.

**Quotes.** The SDK says a double quote in a value is escaped in XML and "not needed in JSON",
which leaves open whether the ETA hashes `"` or `\"`. We never find out: a name is cleaned
before it goes in a receipt (a double quote becomes `'`, a backslash `/`, control characters and
runs of white space one space), so a value is the same text in the JSON and in the hash.

## 9. UUID and chaining

Source: <https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#how-to-generate-receipt-uuid>

1. Build the whole receipt, with the `previousUUID` of the previous receipt of the same POS
   (and, for a return, the `referenceUUID`).
2. Set `header.uuid` to the empty string.
3. Serialize the **receipt object** (section 8).
4. SHA-256 the UTF-8 bytes.
5. The UUID is the hash as 64 hexadecimal characters. We write them in lower case.
6. Put it in `header.uuid`.

The ETA checks that the UUID "is a valid hash of the content of the serialized receipt with all
content excluding the UUID itself", and that `previousUUID` is a 64-character string (or empty
for a POS's first receipt).

**Correcting an invalid receipt**
(<https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#re-submitting-invalid-receipts>): the
corrected receipt gets a new UUID, keeps the `previousUUID` it had, and sets `referenceOldUUID`
to the invalid UUID. Receipts issued after it are not changed. `referenceOldUUID` can't equal
the receipt's own UUID. A correction is accepted up to 96 hours after issue when the old UUID is
a known invalid receipt, 72 hours otherwise.

## 10. Codes

**Payment methods** (<https://sdk.invoicing.eta.gov.eg/codes/payment-methods/>): `C` Cash, `V`
Visa, `CC` Cash with contractor, `VC` Visa with contractor, `VO` Vouchers, `PR` Promotion, `GC`
Gift Card, `P` Points, `O` Others.

| S02 method | Code |
|---|---|
| `cash` | `C` |
| `bank_transfer` | `O` (the SDK has no bank-transfer code) |
| `store_credit` | `O` |

A receipt carries one code and the SDK gives no rule for mixed payments: we send the code with
the largest share of the paid amount (cash wins a tie).

**Tax** (<https://sdk.invoicing.eta.gov.eg/codes/tax-types/>,
<https://sdk.invoicing.eta.gov.eg/files/TaxSubtypes.json>): VAT is `T1`. Its subtypes:

| Subtype | Meaning | Used for |
|---|---|---|
| `V009` | General Item sales | the standard 14% class |
| `V001` | Export | T01's zero-rated class |
| `V003` | Exempted good or service | T01's exempt class |
| `V004` | A non-taxable good or service | |
| `V002`, `V005` to `V008`, `V010` | other exemptions and rates | |

The line's `taxType` and `subType` come from its tax class (`tax_classes.eta_tax_type`,
`eta_subtype`: T01 already seeds the three rows above); `rate` is the line's `tax_rate`. A tax
type may appear once per line.

**Unit type** (<https://sdk.invoicing.eta.gov.eg/codes/unit-types/>): `EA` ("each") for a piece.
Every line sends `EA`: quantities are whole units and `products.unit_of_measure` is free text,
not an ETA code.

**Buyer types:** `B`, `P`, `F` (section 7). **Country:** `EG`. **Currency:** `EGP`.

**Branch code** (<https://sdk.invoicing.eta.gov.eg/codes/branch/>): the branch ID shown in the
taxpayer's profile on the invoicing portal, not the branch name.

**Activity code** (<https://sdk.invoicing.eta.gov.eg/codes/activity-types/>): one of the
taxpayer's registered activity codes.

## 11. Amounts

Source: <https://sdk.invoicing.eta.gov.eg/main-calculations/>. The ETA checks, each with a
tolerance of ±0.5:

- `totalSale = quantity × unitPrice`
- `netSale = totalSale − Σ commercialDiscountData.amount`
- `T1 amount = netSale × rate / 100`
- `total = netSale + T1 amount`
- `totalSales = Σ totalSale`, `totalCommercialDiscount = Σ commercial discounts`,
  `netAmount = Σ netSale`, `taxTotals[T1] = Σ T1 amounts`
- `totalAmount = Σ total − Σ extraReceiptDiscountData.amount + adjustment`
- amounts have up to 5 decimals; a rate above 0 has up to 2.

ETA amounts exclude VAT. Each line is built from the stored sale line, so nothing is recalculated:

| | Prices include VAT | Prices exclude VAT |
|---|---|---|
| `netSale` | `line_total − tax_amount` | `line_total − tax_amount` |
| discount excluding VAT | `discount_amount × 100 / (100 + tax_rate)`, rounded half-up to 2 | `discount_amount` |
| `totalSale` | `netSale` + that discount | `netSale` + that discount (= `unit_price × quantity`) |
| `unitPrice` | `totalSale / quantity`, rounded half-up to 5 decimals | the same |
| T1 `amount` | `tax_amount` | `tax_amount` |
| `total` | `line_total` | `line_total` |

So `total` equals our `line_total` and `totalAmount` equals `sales.total` exactly. The discount
(the line's own plus its share of a whole-sale discount) goes in `commercialDiscountData`, which
lowers the taxable base. Money is written with 2 decimals (`900.00`), `unitPrice` with 5
(`1000.00000`), the rate as stored (`14.00`), quantities as whole numbers.

Example, prices include VAT at 14%: one unit at 1140.00 with a 114.00 discount gives
`netSale 900.00`, discount `100.00`, `totalSale 1000.00`, `unitPrice 1000.00000`, T1 `126.00`,
`total 1026.00`, `totalAmount 1026.00`.

If pre-production refuses a rounding difference, write the rule it enforces here and follow it.

## 12. Return Receipt v1.2: the differences

Source: <https://sdk.invoicing.eta.gov.eg/documents/return-receipt-v1-2/>

- `documentType.receiptType` is `r`.
- `header.referenceUUID` is mandatory: the UUID of the sale receipt. It is written after
  `previousUUID` and before `referenceOldUUID`, and it is part of the return's UUID.
- Optional and not sent: `header.documentUseReason`, `header.salesIssuedDateTime`.
- A return receipt is its own link in the POS chain (it has a `previousUUID` like any receipt).
- Everything else is the Receipt v1.2 structure.
- A return is accepted up to 540 days after the sale receipt was issued.

## 13. Deadlines

Source: <https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#limitations-on-receipt-submission>

| Rule | Value |
|---|---|
| Submit after issue | within 24 hours |
| Later than that | needs a Late Submission Request (out of scope) |
| A corrected receipt (`referenceOldUUID`) | within 96 hours of issue (72 when the old UUID is unknown) |
| Return receipt | within 540 days of the sale receipt |
| `dateTimeIssued` | can't be in the future |

We alert (`eta.failed`, reason `deadline`) when a receipt is still pending 20 hours after issue,
and keep retrying.

## 13a. Corrections (T03)

A receipt the ETA found Invalid (status `rejected`) is **never resent as it is**: the same bytes would be rejected again. It is corrected:

1. The user fixes the data (a product's item code, the seller's or branch's data, the buyer) and asks for a correction. The request only queues an `eta.correct` job (dedupe key `eta.correct:<fiscal id>`); a second request while one is queued is `CORRECTION_QUEUED`.
2. The worker loads the row and goes on only if it is still `rejected` with the same `eta_uuid` the request saw. It builds the receipt again with the same builder, from the **unchanged sale** and the **current** master data.
3. The header carries the rejected receipt's `previousUUID` **unchanged**, `referenceOldUUID` = the rejected UUID, and a **new UUID** (the SDK rule, section 9). A correction of a correction names the latest rejected UUID and keeps the original `previousUUID`.
4. **Nothing changed:** the rebuilt receipt and the stored one are parsed as JSON and compared ignoring `header.uuid`, `header.previousUUID` and `header.referenceOldUUID`. When they are equal the data was not fixed: nothing is stored or sent, the status stays `rejected` and `last_error` becomes `CORRECTION_NOTHING_CHANGED: <the ETA's error>`.
5. **Storing** (`eta_store_correction`, one transaction): lock the row, require `status = 'rejected'` and `eta_uuid` = the expected old UUID (otherwise `CORRECTION_CONFLICT`: the job ends quietly); set the new UUID, `reference_old_uuid` = the old one, the new payload and QR, `status 'pending'`, `attempts 0`, no error; queue `eta.submit` for the POS. The submit job sends every `pending` row that has a UUID, in issue order, so a correction that is not the newest is sent too.
6. **The POS chain head** (`devices.eta_last_uuid`): if it equals the rejected UUID (the rejected receipt was the newest of its POS) it becomes the new UUID, so the next sale chains to the correction. Otherwise it is left alone: later receipts already chain from it, and forking the chain is worse. **To verify in pre-production:** that the ETA accepts a correction that takes the head's place, and one that is sent after later receipts of the same POS.
7. The rejected UUID is never lost: `fiscal_submissions.reference_old_uuid` and the append-only `fiscal_events` log (every status, UUID and error change of a receipt).

Deadlines shown by the monitor (it never blocks on them): a first submission within 24 hours of the sale; a correction within 96 hours (section 13). A receipt past its deadline needs a Late Submission Request in the ETA portal (out of scope).

## 14. QR code

Source: <https://sdk.invoicing.eta.gov.eg/receiptissuancefaq/#receipt-qr-code>

One line of text:

```
{portal URL}/receipts/search/{uuid}/share/{dateTimeIssued}#Total:{totalAmount},IssuerRIN:{rin}
```

SDK example:

```
http://invoicing.eta.gov.eg/receipts/search/68e656b251e67e8358bef8483ab0d51c6619f3e7a1a9f0e75838d41ff368f320/share/2022-02-19T02:00Z#Total:1000.000,IssuerRIN:674859545
```

We use the portal URL of the shop's environment (section 1), and the receipt's own
`dateTimeIssued` and `totalAmount` text unchanged, for example
`.../share/2026-10-12T09:15:02Z#Total:1026.00,IssuerRIN:674859545`. The SDK's example drops the
seconds and shows three decimals; it gives no fixed format for either **(unverified)**.

## 15. Where the SDK differs from the T02 task file

| # | Task file ("Facts") | SDK | Followed |
|---|---|---|---|
| 1 | Serialization: "for an array write `"NAMEUPPER"` before each element" | The name is written once for the array **and** again before each element (N + 1 times). Confirmed by the worked example. | SDK |
| 2 | Says nothing about number text | Values are serialized exactly as written in the document (`10.50` stays `10.50`), so the JSON sent must carry the hashed number text | SDK: own JSON writer, exact text stored |
| 3 | Body `{ receipts, signatures }`; validation "not yet deployed" | Same, but the page also says the issuer signature "must be present"; the batch sample sends `"signatures": [ ]`, the Postman sample omits the key | `"signatures": []` (unverified) |
| 4 | `receiptType` `s` | The document page says `s`; the SDK's Postman sample sends `S` | `s` |
| 5 | Returns include "the original's reference UUID" | The field is `header.referenceUUID`, mandatory, after `previousUUID`; type `r` | SDK |
| 6 | "the ETA receipt lookup by UUID" (no endpoint named) | `GET /api/v1/receipts/{uuid}/raw` | SDK |
| 7 | "Use the SDK rule for mixed payments" | There is no rule, and no bank-transfer code | Largest share; bank transfer and store credit are `O` |
| 8 | QR `{dateTimeIssued UTC}`, `{totalAmount}` | Same template; the example drops the seconds and shows 3 decimals | The receipt's own text (unverified) |
| 9 | `P` needs an ID from 150,000 EGP | Also: a `P` id that is present must be 14 digits, a `B` id 9 digits and not the seller's, `seller.rin` 9 digits | SDK: these also block (`BUYER_ID`, `SELLER_DATA`) |
| 10 | Batches "default 50, or the SDK limit if lower" | 500 receipts and 1.5 MB per submission, 300 lines per receipt, one POS per submission | 50, split at 1.4 MB |
| 11 | Correction keeps `previousUUID`, sets `referenceOldUUID` | Same, and only within 96 hours of issue (72 when the old UUID is unknown) | SDK |
| 12 | Says nothing about tolerance | Every calculation check allows ±0.5 | Our figures are exact to the piaster, well inside it |
| 13 | Says nothing about certificates | Pre-production needs its root CA trusted | `NODE_EXTRA_CA_CERTS`, documented in `SETUP.md` |
| 14 | General Receipt v1.2 | Sector receipts exist (Retail `SR`); allowed types depend on the activity code | General `s` (unverified) |

Neither stop condition applies: the SDK does not require a working signature today (its
validation is not deployed), and the UUID can be computed as described once row 1 is applied.

## 16. Offline receipts (S08)

When the POS is offline (S08, EC-75), the **device** builds the receipt, with the same code as the
server: T02's serializer, receipt builder and QR text live in the contracts package and are used by
both.

| Step | Who | What |
|---|---|---|
| Build | device | the Receipt v1.2 body of the offline sale (sections 6–11), `previousUUID` = the device's last receipt UUID (the chain head of its lease, then its own last offline receipt) |
| UUID, QR | device | the UUID of section 9 (WebCrypto SHA-256) and the QR text of section 14; both printed on the paper receipt |
| Sign and store | device | the receipt JSON text is part of the signed sale content (ECDSA P-256), saved before printing |
| Receive | server | the receipt text is kept exactly as the device wrote it (Postgres `json`, number text kept); the fiscal row's `payload.receipt_json` is that text |
| Verify | worker | the signature, then the UUID recomputed from the receipt; the receipt must match the sale it belongs to (number, time, totals, lines) |
| Release and send | worker, then T02 | a verified receipt is released and T02's submit job sends it **unchanged**; the server never rebuilds or re-chains it |

**Chain (fork rule).** Receiving offline receipts moves the device's chain head to the last offline
UUID, so the next online receipt chains to it. If an offline batch did not start at the head (another
receipt took the head meanwhile), the fork is logged as a `chain_fork` event and the head still moves:
the ETA checks only the format of `previousUUID`.

**Release is independent of business conflicts.** A sale that waits for a manager (closed shift, a
serial sold meanwhile, a limit, a price) is still released and submitted: the paper receipt exists and
the 24-hour deadline runs. Only two **holds** stop a release:

| Hold | When | Ends with |
|---|---|---|
| `RECEIPT_MISMATCH` | the receipt does not match its sale (a bug) | an alert; never sent |
| `LEASE_REVOKED` | the sale was made after the device was unpaired or deactivated | the manager accepts it (released) or rejects it (lost or stolen device: the fiscal row is cancelled, never sent) |

A verification failure (signature or UUID) rejects the sale and cancels its fiscal row: it is never
sent. An offline sale whose online attempt reached the server after all is a duplicate: the online
receipt stands, the offline fiscal row is cancelled.

**Margins.** An offline lease lasts at most 20 hours (`offline_max_hours`, 1–20), which leaves at
least 4 hours to sync and submit before the ETA's 24-hour limit. The POS turns its banner red when an
unsynced sale is 18 hours old, and T02's deadline alert (section 13) fires when a released receipt is
still pending 20 hours after issue.
