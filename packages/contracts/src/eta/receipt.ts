// contracts/src/eta/receipt.ts (moved from server/src/eta/build-receipt.ts by S08, D7: the server
// and the offline POS build the same receipt; no Node API here).
//
// T02 (D67). A stored sale -> an ETA Receipt v1.2 (docs/eta/ERECEIPT_SPEC.md, sections 6, 7, 10
// and 11). Nothing is priced again: every figure comes from the sale lines as they were stored,
// so each line's `total` is our line_total and `totalAmount` is the sale's total. ETA amounts
// exclude VAT. Decimals are strings from the F12 money helpers, never JS numbers.
//
// The receipt is returned with header.uuid empty: hashing stays outside (D7). The server fills it
// with Node's crypto (server/src/eta/uuid.ts), the POS with crypto.subtle, both over
// receiptUuidInput().
//
// A receipt that can't be built because data is missing throws ReceiptBlockedError with the code
// the fiscal row is then blocked with (decision 4). Its message never carries a national ID.

import {
  addMoney,
  compareMoney,
  divideMoney,
  roundMoney,
  subtractMoney,
  sumMoney,
  taxFromGross,
} from '../money.js';
import { cleanText, dec, serialize, type EtaDecimal, type EtaObject } from './serialize.js';

export type BlockCode =
  | 'BLOCKED:NO_DEVICE'
  | 'BLOCKED:ITEM_CODE'
  | 'BLOCKED:SELLER_DATA'
  | 'BLOCKED:BUYER_ID'
  | 'BLOCKED:RETURN_TOO_LATE';

export class ReceiptBlockedError extends Error {
  readonly code: BlockCode;

  constructor(code: BlockCode, message: string) {
    super(message);
    Object.setPrototypeOf(this, ReceiptBlockedError.prototype);
    this.name = 'ReceiptBlockedError';
    this.code = code;
  }
}

/** One stored sale line with what the receipt needs from its product and tax class. */
export interface SourceLine {
  line_no: number;
  quantity: number;
  unit_price: string;
  /** Its own discount plus its share of a whole-sale discount (VAT included when prices are). */
  discount_amount: string;
  tax_rate: string;
  tax_amount: string;
  line_total: string;
  sku: string;
  name: string;
  eta_item_code: string | null;
  eta_item_type: string | null;
  eta_tax_type: string;
  eta_subtype: string;
}

/** Everything a receipt is built from: the sale as stored, plus the seller, buyer and POS. */
export interface ReceiptSource {
  sale: {
    number: string;
    /** UTC, whole seconds: 2026-10-12T09:15:02Z. */
    issued_at: string;
    prices_include_vat: boolean;
    total: string;
  };
  lines: readonly SourceLine[];
  payments: readonly { method: string; amount: string }[];
  /** null = a walk-in customer. */
  customer: {
    name: string;
    national_id: string | null;
    is_business: boolean;
    tax_registration_no: string | null;
  } | null;
  seller: {
    rin: string | null;
    name: string | null;
    activity_code: string | null;
    branch_code: string | null;
    governorate: string | null;
    city: string | null;
    street: string | null;
    building_number: string | null;
  };
  /** null = the sale was made without a POS. */
  device: { serial: string | null; status: string; is_active: boolean } | null;
}

/** `Discount` in T02; renamed in contracts, where `Discount` is S03's discount input. */
export type ReceiptDiscount = { amount: EtaDecimal; description: string };
export type TaxableItem = {
  taxType: string;
  amount: EtaDecimal;
  subType: string;
  rate: EtaDecimal;
};
export type ReceiptItem = {
  internalCode: string;
  description: string;
  itemType: string;
  itemCode: string;
  unitType: string;
  quantity: EtaDecimal;
  unitPrice: EtaDecimal;
  netSale: EtaDecimal;
  totalSale: EtaDecimal;
  total: EtaDecimal;
  commercialDiscountData?: ReceiptDiscount[];
  taxableItems: TaxableItem[];
};
export type ReceiptHeader = {
  dateTimeIssued: string;
  receiptNumber: string;
  uuid: string;
  previousUUID: string;
  /** Return receipts only: the UUID of the sale receipt. */
  referenceUUID?: string;
  referenceOldUUID: string;
  currency: string;
  exchangeRate: EtaDecimal;
};
export type ReceiptSeller = {
  rin: string;
  companyTradeName: string;
  branchCode: string;
  branchAddress: {
    country: string;
    governate: string;
    regionCity: string;
    street: string;
    buildingNumber: string;
  };
  deviceSerialNumber: string;
  activityCode: string;
};
export type ReceiptBuyer = { type: 'P' | 'B'; id?: string; name?: string };
export type TaxTotal = { taxType: string; amount: EtaDecimal };

/** Properties in the order the SDK lists them: the order is part of the UUID. */
export type Receipt = {
  header: ReceiptHeader;
  documentType: { receiptType: string; typeVersion: string };
  seller: ReceiptSeller;
  buyer: ReceiptBuyer;
  itemData: ReceiptItem[];
  totalSales: EtaDecimal;
  totalCommercialDiscount: EtaDecimal;
  totalItemsDiscount: EtaDecimal;
  netAmount: EtaDecimal;
  feesAmount: EtaDecimal;
  totalAmount: EtaDecimal;
  taxTotals: TaxTotal[];
  paymentMethod: string;
  adjustment: EtaDecimal;
};

export const RECEIPT_TYPE_SALE = 's';
export const RECEIPT_TYPE_RETURN = 'r';
export const RECEIPT_TYPE_VERSION = '1.2';
/** From this total on, a person's national ID and name are mandatory. */
export const BUYER_ID_THRESHOLD = '150000.00';
/** "each": every line is sold in whole units. */
const UNIT_TYPE = 'EA';
const ISSUED_AT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

/** A receipt UUID: 64 lower-case hex characters (docs/eta/ERECEIPT_SPEC.md, section 9). */
export const UUID_PATTERN = /^[0-9a-f]{64}$/;

/** Any receipt: only the header's uuid matters here. */
export interface HasReceiptHeader extends EtaObject {
  readonly header: EtaObject & { readonly uuid: string };
}

/**
 * The text a receipt's UUID is the SHA-256 of (UTF-8): the receipt serialized with header.uuid
 * empty, whatever it holds now. The caller hashes it (Node crypto or crypto.subtle).
 */
export function receiptUuidInput(receipt: HasReceiptHeader): string {
  return serialize({ ...receipt, header: { ...receipt.header, uuid: '' } });
}

/** The same receipt with this UUID in its header (property order unchanged). */
export function withReceiptUuid<T extends HasReceiptHeader>(receipt: T, uuid: string): T {
  if (!UUID_PATTERN.test(uuid)) throw new RangeError('Not a receipt UUID');
  return { ...receipt, header: { ...receipt.header, uuid } };
}

const digits = (value: string | null | undefined): string => (value ?? '').replace(/\D/g, '');

function seller(source: ReceiptSource): ReceiptSeller {
  const device = source.device;
  const serial = cleanText(device?.serial, 100);
  if (!device)
    throw new ReceiptBlockedError('BLOCKED:NO_DEVICE', 'the sale was made without a POS');
  if (!device.is_active || device.status !== 'active' || serial === '') {
    throw new ReceiptBlockedError(
      'BLOCKED:NO_DEVICE',
      'the POS is not active with the ETA or has no serial',
    );
  }

  const s = source.seller;
  const fields = {
    'tax registration number': /^\d{9}$/.test(digits(s.rin)) ? digits(s.rin) : '',
    'company name': cleanText(s.name, 200),
    'activity code': cleanText(s.activity_code, 10),
    'branch code': cleanText(s.branch_code, 50),
    'branch governorate': cleanText(s.governorate, 100),
    'branch city': cleanText(s.city, 100),
    'branch street': cleanText(s.street, 200),
    'branch building number': cleanText(s.building_number, 100),
  };
  const missing = Object.entries(fields)
    .filter(([, value]) => value === '')
    .map(([name]) => name);
  if (missing.length > 0) {
    throw new ReceiptBlockedError('BLOCKED:SELLER_DATA', `missing: ${missing.join(', ')}`);
  }

  return {
    rin: fields['tax registration number'],
    companyTradeName: fields['company name'],
    branchCode: fields['branch code'],
    branchAddress: {
      country: 'EG',
      governate: fields['branch governorate'],
      regionCity: fields['branch city'],
      street: fields['branch street'],
      buildingNumber: fields['branch building number'],
    },
    deviceSerialNumber: serial,
    activityCode: fields['activity code'],
  };
}

function items(source: ReceiptSource): ReceiptItem[] {
  const uncoded = source.lines.filter(
    (line) =>
      cleanText(line.eta_item_code, 100) === '' ||
      (line.eta_item_type !== 'EGS' && line.eta_item_type !== 'GS1'),
  );
  if (uncoded.length > 0) {
    throw new ReceiptBlockedError(
      'BLOCKED:ITEM_CODE',
      `no ETA item code: ${uncoded.map((line) => cleanText(line.sku, 50)).join(', ')}`,
    );
  }

  return source.lines.map((line) => {
    const netSale = subtractMoney(line.line_total, line.tax_amount);
    const discount = source.sale.prices_include_vat
      ? taxFromGross(line.discount_amount, line.tax_rate).net
      : roundMoney(line.discount_amount);
    const totalSale = addMoney(netSale, discount);
    return {
      internalCode: cleanText(line.sku, 50),
      description: cleanText(line.name, 500),
      itemType: line.eta_item_type ?? '',
      itemCode: cleanText(line.eta_item_code, 100),
      unitType: UNIT_TYPE,
      quantity: dec(String(line.quantity)),
      unitPrice: dec(divideMoney(totalSale, line.quantity, 5)),
      netSale: dec(netSale),
      totalSale: dec(totalSale),
      total: dec(roundMoney(line.line_total)),
      ...(compareMoney(discount, '0.00') > 0
        ? { commercialDiscountData: [{ amount: dec(discount), description: 'Discount' }] }
        : {}),
      taxableItems: [
        {
          taxType: line.eta_tax_type,
          amount: dec(roundMoney(line.tax_amount)),
          subType: line.eta_subtype,
          rate: dec(line.tax_rate),
        },
      ],
    };
  });
}

function buyer(source: ReceiptSource): ReceiptBuyer {
  const customer = source.customer;
  const needsId = compareMoney(roundMoney(source.sale.total), BUYER_ID_THRESHOLD) >= 0;
  const name = cleanText(customer?.name, 100);

  if (customer?.is_business) {
    const rin = digits(customer.tax_registration_no);
    if (!/^\d{9}$/.test(rin) || name === '' || rin === digits(source.seller.rin)) {
      throw new ReceiptBlockedError(
        'BLOCKED:BUYER_ID',
        `a business buyer needs a name and a 9-digit tax registration number other than the shop's`,
      );
    }
    return { type: 'B', id: rin, name };
  }
  if (!needsId) return name === '' ? { type: 'P' } : { type: 'P', name };

  const nationalId = digits(customer?.national_id);
  if (!/^\d{14}$/.test(nationalId) || name === '') {
    throw new ReceiptBlockedError(
      'BLOCKED:BUYER_ID',
      `a sale of ${BUYER_ID_THRESHOLD} EGP or more needs the buyer's name and national ID`,
    );
  }
  return { type: 'P', id: nationalId, name };
}

/** S02's methods as ETA codes. The SDK has no bank-transfer code: it is "Others". */
const PAYMENT_CODES: Readonly<Record<string, string>> = {
  cash: 'C',
  bank_transfer: 'O',
  store_credit: 'O',
};

/**
 * A receipt carries one payment code and the SDK has no rule for a mixed payment: the code with
 * the largest share of what was paid; cash wins a tie. No payment lines: cash.
 */
export function paymentMethodCode(payments: ReceiptSource['payments']): string {
  const byCode = new Map<string, string>();
  for (const payment of payments) {
    const code = PAYMENT_CODES[payment.method] ?? 'O';
    byCode.set(code, addMoney(byCode.get(code) ?? '0.00', roundMoney(payment.amount)));
  }
  let best = 'C';
  let bestAmount = byCode.get('C') ?? '0.00';
  for (const [code, amount] of byCode) {
    if (compareMoney(amount, bestAmount) > 0) {
      best = code;
      bestAmount = amount;
    }
  }
  return best;
}

function taxTotals(lines: readonly ReceiptItem[]): TaxTotal[] {
  const byType = new Map<string, string>();
  for (const line of lines) {
    for (const tax of line.taxableItems) {
      byType.set(tax.taxType, addMoney(byType.get(tax.taxType) ?? '0.00', tax.amount.text));
    }
  }
  return [...byType].map(([taxType, amount]) => ({ taxType, amount: dec(amount) }));
}

/**
 * The receipt or return receipt of a stored document, with header.uuid empty (the caller hashes
 * receiptUuidInput() and fills it with withReceiptUuid()).
 * `previousUuid`: the UUID of the POS's previous receipt, "" for its first.
 * `referenceUuid`: a return's sale receipt.
 * `referenceOldUuid`: the rejected receipt this one corrects (T03), "" for a first submission.
 */
export function buildDocumentBody(
  receiptType: typeof RECEIPT_TYPE_SALE | typeof RECEIPT_TYPE_RETURN,
  source: ReceiptSource,
  previousUuid: string,
  referenceUuid?: string,
  referenceOldUuid = '',
): Receipt {
  if (previousUuid !== '' && !UUID_PATTERN.test(previousUuid)) {
    throw new RangeError('previousUuid must be a receipt UUID or empty');
  }
  if (referenceOldUuid !== '' && !UUID_PATTERN.test(referenceOldUuid)) {
    throw new RangeError('referenceOldUuid must be a receipt UUID or empty');
  }
  if (!ISSUED_AT_PATTERN.test(source.sale.issued_at)) {
    throw new RangeError('issued_at must be UTC with whole seconds');
  }
  if (source.lines.length === 0) throw new RangeError('A receipt needs at least one line');

  const sellerData = seller(source);
  const lines = items(source);
  const buyerData = buyer(source);

  const totalAmount = sumMoney(lines.map((line) => line.total.text));
  if (compareMoney(totalAmount, roundMoney(source.sale.total)) !== 0) {
    // The stored lines always add up to the stored total: anything else is a data fault, and a
    // receipt with another total than the sale must never go out.
    throw new Error(`Receipt ${source.sale.number}: the lines do not add up to the total`);
  }

  return {
    header: {
      dateTimeIssued: source.sale.issued_at,
      receiptNumber: cleanText(source.sale.number, 50),
      uuid: '',
      previousUUID: previousUuid,
      ...(referenceUuid === undefined ? {} : { referenceUUID: referenceUuid }),
      referenceOldUUID: referenceOldUuid,
      currency: 'EGP',
      exchangeRate: dec('0'),
    },
    documentType: { receiptType, typeVersion: RECEIPT_TYPE_VERSION },
    seller: sellerData,
    buyer: buyerData,
    itemData: lines,
    totalSales: dec(sumMoney(lines.map((line) => line.totalSale.text))),
    totalCommercialDiscount: dec(
      sumMoney(
        lines.flatMap((line) => (line.commercialDiscountData ?? []).map((d) => d.amount.text)),
      ),
    ),
    totalItemsDiscount: dec('0'),
    netAmount: dec(sumMoney(lines.map((line) => line.netSale.text))),
    feesAmount: dec('0'),
    totalAmount: dec(totalAmount),
    taxTotals: taxTotals(lines),
    paymentMethod: paymentMethodCode(source.payments),
    adjustment: dec('0'),
  };
}

/** A sale's Receipt v1.2 (type `s`), with header.uuid empty. */
export function buildReceiptBody(
  source: ReceiptSource,
  previousUuid: string,
  referenceOldUuid = '',
): Receipt {
  return buildDocumentBody(RECEIPT_TYPE_SALE, source, previousUuid, undefined, referenceOldUuid);
}
