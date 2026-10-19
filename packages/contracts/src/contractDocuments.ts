import { z } from 'zod';
import { BusinessDate, Money, Uuid } from './common.js';
import { Contract } from './installments.js';
import { PromissoryNotesMode } from './settings.js';

/**
 * N07 printed contract and promissory notes (D82). The client draws both documents from one read
 * (`GET /api/contracts/:id/documents`); every amount and date on the paper comes from that answer.
 * Words: installment price and profit, never interest (docs/ISLAMIC_FINANCE_RULES.md rules 1, 3, 4, 6).
 */

export const CONTRACT_DOCUMENT_KINDS = ['contract', 'promissory_notes'] as const;
export const ContractDocumentKind = z.enum(CONTRACT_DOCUMENT_KINDS);
export type ContractDocumentKind = z.infer<typeof ContractDocumentKind>;

/** The longest terms text a shop may save. */
export const CONTRACT_TERMS_MAX_LENGTH = 20000;

export const ContractDocumentPrintBody = z.object({ document: ContractDocumentKind }).strict();
export type ContractDocumentPrintBody = z.infer<typeof ContractDocumentPrintBody>;

/** The answer of `POST /api/contracts/:id/document-prints`: print 1 of a schedule version is the original. */
export const ContractDocumentPrint = z.object({
  print_no: z.number().int().positive(),
  copy: z.boolean(),
});
export type ContractDocumentPrint = z.infer<typeof ContractDocumentPrint>;

const PrintCounter = z.object({ next_print_no: z.number().int().positive(), copy: z.boolean() });

/** The person on the paper. The national ID is printed in full (it is on the signed paper). */
export const DocumentParty = z.object({
  id: Uuid,
  name: z.string(),
  national_id: z.string().nullable(),
  address: z.string().nullable(),
  job: z.string().nullable(),
  phone: z.string().nullable(),
});
export type DocumentParty = z.infer<typeof DocumentParty>;

export const DocumentGuarantor = DocumentParty.extend({ relation: z.string().nullable() });
export type DocumentGuarantor = z.infer<typeof DocumentGuarantor>;

/** A good on the contract. No line total: the cash line totals would put a cash price beside the installment price (rule 1). */
export const DocumentGood = z.object({ name: z.string(), quantity: z.number().int().positive() });
export type DocumentGood = z.infer<typeof DocumentGood>;

export const DocumentShop = z.object({
  name: z.string(),
  legal_name: z.string().nullable(),
  commercial_register: z.string().nullable(),
  tax_registration_no: z.string().nullable(),
  address: z.string().nullable(),
  phone: z.string().nullable(),
  logo_file_id: Uuid.nullable(),
  branch: z.object({
    name: z.string(),
    address: z.string().nullable(),
    city: z.string().nullable(),
    phone: z.string().nullable(),
  }),
});
export type DocumentShop = z.infer<typeof DocumentShop>;

/** One promissory note. `seq` is null for the single note of a shop that chose `single`. */
export const PromissoryNote = z.object({
  /** `{contract number}-{seq}` or `{contract number}-T` for the single note. */
  number: z.string(),
  seq: z.number().int().positive().nullable(),
  amount: Money,
  due_date: BusinessDate,
  /** The branch's city (or its address when it has no city). */
  place: z.string().nullable(),
  /** The contract's date, or the print date for a schedule that replaced an earlier one. */
  issue_date: BusinessDate,
});
export type PromissoryNote = z.infer<typeof PromissoryNote>;

export const CONTRACT_STATUS_MARKS = ['completed', 'written_off', 'returned'] as const;

/**
 * The contract as it is printed: N02's contract JSON of the current schedule version without the
 * cash price (rule 1: only the installment price is on the paper), the customer and the guarantors
 * (they come with their full details below).
 */
export const ContractDocumentContract = Contract.omit({
  cash_price: true,
  customer: true,
  guarantors: true,
}).extend({ contract_date: BusinessDate });
export type ContractDocumentContract = z.infer<typeof ContractDocumentContract>;

export const ContractDocuments = z.object({
  contract: ContractDocumentContract,
  customer: DocumentParty,
  guarantors: z.array(DocumentGuarantor),
  goods: z.array(DocumentGood),
  shop: DocumentShop,
  /** `text` is null while the shop uses the default text (`DEFAULT_CONTRACT_TERMS_AR`). */
  terms: z.object({ text: z.string().nullable(), is_default: z.boolean() }),
  notes_mode: PromissoryNotesMode,
  /** Empty when the contract is not open or nothing is left. */
  notes: z.array(PromissoryNote),
  prints: z.object({ contract: PrintCounter, promissory_notes: PrintCounter }),
  /** The status across the top of a closed contract's paper. */
  status_mark: z.enum(CONTRACT_STATUS_MARKS).nullable(),
  /** After a reschedule: the schedule version and date the current one replaces. */
  replaces: z.object({ version: z.number().int().positive(), date: BusinessDate }).nullable(),
  /** Today in the shop's time zone: the print date. */
  today: BusinessDate,
});
export type ContractDocuments = z.infer<typeof ContractDocuments>;

// ---------------------------------------------------------------------------------------------
// The terms text

/** The only `{{name}}` placeholders a terms text may use. */
export const CONTRACT_TEMPLATE_PLACEHOLDERS = [
  'shop_name',
  'shop_legal_name',
  'commercial_register',
  'branch_name',
  'city',
  'contract_number',
  'contract_date',
  'customer_name',
  'customer_national_id',
  'installment_price',
  'installment_price_words',
  'down_payment',
  'installments_count',
  'frequency',
  'first_due_date',
  'last_due_date',
] as const;
export type ContractTemplatePlaceholder = (typeof CONTRACT_TEMPLATE_PLACEHOLDERS)[number];

/**
 * Wording the shop may not put on the paper (rules 3, 4, 6: no interest, no late fee, no early
 * settlement discount promised). Matched case-insensitively after removing Arabic diacritics. The
 * migration holds the same list (a test compares them).
 */
export const CONTRACT_TEMPLATE_FORBIDDEN_WORDS = [
  'فائدة',
  'فوائد',
  'سعر الفائدة',
  'قرض',
  'غرامة',
  'غرامات',
  'غرامة تأخير',
  'خصم السداد المبكر',
  'interest',
  'loan',
  'late fee',
  'penalty',
] as const;

const DIACRITICS = /[ً-ٰٟـ]/g;
const PLACEHOLDER = /\{\{([^{}]*)\}\}/g;

function normalizeForCheck(text: string): string {
  return text.replace(DIACRITICS, '').toLowerCase();
}

export interface ContractTemplateCheck {
  ok: boolean;
  /** Placeholders that are not in the fixed list, as written. */
  unknown: string[];
  /** Forbidden wording found. */
  words: string[];
}

/** The same checks as the server: unknown placeholders and forbidden wording. */
export function checkContractTemplate(text: string): ContractTemplateCheck {
  const known = new Set<string>(CONTRACT_TEMPLATE_PLACEHOLDERS);
  const unknown: string[] = [];
  for (const match of text.matchAll(PLACEHOLDER)) {
    const name = (match[1] ?? '').trim();
    if (!known.has(name) && !unknown.includes(name)) unknown.push(name);
  }
  const normalized = normalizeForCheck(text);
  const words = CONTRACT_TEMPLATE_FORBIDDEN_WORDS.filter((w) => normalized.includes(w));
  return { ok: unknown.length === 0 && words.length === 0, unknown, words };
}

/** Fills the placeholders; a placeholder without a value prints as an empty string. */
export function renderContractTemplate(
  text: string,
  values: Partial<Record<ContractTemplatePlaceholder, string>>,
): string {
  return text.replace(PLACEHOLDER, (_all, raw: string) => {
    const name = raw.trim() as ContractTemplatePlaceholder;
    return values[name] ?? '';
  });
}

/**
 * The terms printed while the shop has not written its own. A deferred-price sale of goods the
 * shop owns; the installment price and schedule are fixed; nothing about interest, late fees or
 * discounts (rules 1, 3, 4, 6).
 */
export const DEFAULT_CONTRACT_TERMS_AR = [
  '١. باع الطرف الأول ({{shop_legal_name}}) إلى الطرف الثاني ({{customer_name}}) السلع الموضحة بهذا العقد، وهي مملوكة للطرف الأول ملكًا تامًا وقت البيع، بيعًا بثمن مؤجل يُسدَّد على أقساط.',
  '٢. سعر البيع بالتقسيط المتفق عليه هو {{installment_price}} ({{installment_price_words}})، ويشمل ربح البائع، وهو ثابت من تاريخ توقيع هذا العقد ولا يتغير.',
  '٣. يدفع الطرف الثاني مقدمًا مبلغ {{down_payment}}، ويسدد الباقي على {{installments_count}} قسطًا ({{frequency}}) في المواعيد المبينة بجدول الأقساط، أولها {{first_due_date}} وآخرها {{last_due_date}}.',
  '٤. يلتزم الطرف الثاني بسداد كل قسط في تاريخ استحقاقه، ويكون السداد في فروع الطرف الأول أو لدى مندوبه المعتمد مقابل إيصال رسمي.',
  '٥. تنتقل ملكية السلع إلى الطرف الثاني عند تسلمها، ويقر بأنه عاينها وتسلمها سليمة وخالية من العيوب الظاهرة.',
  '٦. الضامنون المذكورون بهذا العقد متضامنون مع الطرف الثاني في سداد الأقساط المتبقية، ويجوز للطرف الأول مطالبة أي منهم.',
  '٧. يقر الطرفان والضامنون بصحة البيانات الواردة بهذا العقد، وبأن عناوينهم المذكورة فيه هي محال إقامتهم المختارة للإخطارات.',
  '٨. تختص محاكم مدينة {{city}} بنظر أي نزاع ينشأ عن هذا العقد.',
  '٩. حُرر هذا العقد من نسختين بيد كل طرف نسخة للعمل بموجبها.',
].join('\n');

// ---------------------------------------------------------------------------------------------
// Error details

export const TemplateInvalidDetail = z.object({ unknown: z.array(z.string()) });
export type TemplateInvalidDetail = z.infer<typeof TemplateInvalidDetail>;
export const TemplateNotAllowedDetail = z.object({ words: z.array(z.string()) });
export type TemplateNotAllowedDetail = z.infer<typeof TemplateNotAllowedDetail>;

// ---------------------------------------------------------------------------------------------
// Amount in words

const ONES = [
  '',
  'واحد',
  'اثنان',
  'ثلاثة',
  'أربعة',
  'خمسة',
  'ستة',
  'سبعة',
  'ثمانية',
  'تسعة',
  'عشرة',
  'أحد عشر',
  'اثنا عشر',
  'ثلاثة عشر',
  'أربعة عشر',
  'خمسة عشر',
  'ستة عشر',
  'سبعة عشر',
  'ثمانية عشر',
  'تسعة عشر',
];
const TENS = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
const HUNDREDS = [
  '',
  'مائة',
  'مائتان',
  'ثلاثمائة',
  'أربعمائة',
  'خمسمائة',
  'ستمائة',
  'سبعمائة',
  'ثمانمائة',
  'تسعمائة',
];

/** 1..99 as a bare number (masculine, as for pounds and piasters). */
function below100(n: number): string {
  if (n < 20) return ONES[n] ?? '';
  const ones = n % 10;
  const tens = TENS[Math.floor(n / 10)] ?? '';
  return ones === 0 ? tens : `${ONES[ones]} و${tens}`;
}

interface Noun {
  one: string; // "جنيه"
  two: string; // "جنيهان"
  plural: string; // "جنيهات"
  acc: string; // "جنيهًا"
}

const POUND: Noun = {
  one: 'جنيه',
  two: 'جنيهان',
  plural: 'جنيهات',
  acc: 'جنيهًا',
};
const PIASTER: Noun = {
  one: 'قرش',
  two: 'قرشان',
  plural: 'قروش',
  acc: 'قرشًا',
};

interface Scale {
  one: string;
  two: string;
  twoBound: string; // the dual when the counted noun follows directly ("ألفا جنيه")
  plural: string;
  acc: string;
}
const SCALES: Scale[] = [
  { one: 'ألف', two: 'ألفان', twoBound: 'ألفا', plural: 'آلاف', acc: 'ألفًا' },
  { one: 'مليون', two: 'مليونان', twoBound: 'مليونا', plural: 'ملايين', acc: 'مليونًا' },
  { one: 'مليار', two: 'ملياران', twoBound: 'مليارا', plural: 'مليارات', acc: 'مليارًا' },
];

/** A count (1..999) of a scale word: thousands, millions, billions. `bound`: the counted noun follows. */
function scaleCount(group: number, scale: Scale, bound: boolean): string {
  const hundreds = Math.floor(group / 100);
  const rest = group % 100;
  const two = bound ? scale.twoBound : scale.two;
  const parts: string[] = [];
  if (hundreds > 0) {
    // 200 before a noun (or before a scale word): "مائتا ألف".
    parts.push(rest === 0 && hundreds === 2 ? 'مائتا' : (HUNDREDS[hundreds] ?? ''));
  }
  if (rest === 0) return `${parts.join(' ')} ${scale.one}`.trim();
  let tail: string;
  if (rest === 1) tail = scale.one;
  else if (rest === 2) tail = two;
  else if (rest <= 10) tail = `${below100(rest)} ${scale.plural}`;
  // Before the counted noun the scale word stays singular: "أحد عشر ألف جنيه".
  else tail = `${below100(rest)} ${bound ? scale.one : scale.acc}`;
  return [...parts, tail].join(' و');
}

/** A whole number of units (0 < n < 10^12) with its counted noun, e.g. pounds. */
function countWithNoun(n: number, noun: Noun): string {
  const groups = [
    n % 1000,
    Math.floor(n / 1000) % 1000,
    Math.floor(n / 1e6) % 1000,
    Math.floor(n / 1e9),
  ];
  const [units = 0, thousands = 0, millions = 0, billions = 0] = groups;
  const rest = units % 100;
  const hundreds = Math.floor(units / 100);
  // The noun follows the last part directly when the number ends with a round hundred or scale.
  const endsRound = rest === 0;
  const lastScaleIndex = units === 0 ? (thousands > 0 ? 0 : millions > 0 ? 1 : 2) : -1;
  const parts: string[] = [];
  const scaled = [
    { g: billions, i: 2 },
    { g: millions, i: 1 },
    { g: thousands, i: 0 },
  ];
  for (const { g, i } of scaled) {
    if (g === 0) continue;
    const scale = SCALES[i];
    if (scale === undefined) continue;
    parts.push(scaleCount(g, scale, endsRound && units === 0 && i === lastScaleIndex));
  }
  if (hundreds > 0) {
    parts.push(rest === 0 && hundreds === 2 ? 'مائتا' : (HUNDREDS[hundreds] ?? ''));
  }
  if (rest === 0) {
    // Round number: the counted noun follows the last part directly ("ألف جنيه").
    return `${parts.join(' و')} ${noun.one}`;
  }
  let phrase: string;
  if (rest === 1) phrase = `${noun.one} واحد`;
  else if (rest === 2) phrase = noun.two;
  else if (rest <= 10) phrase = `${below100(rest)} ${noun.plural}`;
  else phrase = `${below100(rest)} ${noun.acc}`;
  // "جنيه واحد" keeps its number inside the noun phrase; the rest of the number comes before it.
  parts.push(phrase);
  return parts.join(' و');
}

/**
 * The amount in Arabic words for the cheque line of a note or the contract: Egyptian pounds and
 * piasters ("ألف ومائتان وخمسون جنيهًا وخمسون قرشًا فقط لا غير"), up to 999 999 999 999.99.
 * The amount must not be negative.
 */
export function amountInWordsAr(money: Money): string {
  const match = /^(\d{1,12})(?:\.(\d{1,2}))?$/.exec(money);
  if (match === null) throw new RangeError(`Cannot write ${money} in words`);
  const pounds = Number(match[1]);
  const piasters = Number((match[2] ?? '').padEnd(2, '0') || '0');
  const phrases: string[] = [];
  if (pounds > 0) phrases.push(countWithNoun(pounds, POUND));
  if (piasters > 0) phrases.push(countWithNoun(piasters, PIASTER));
  if (phrases.length === 0) phrases.push('صفر جنيه');
  return `${phrases.join(' و')} فقط لا غير`;
}
