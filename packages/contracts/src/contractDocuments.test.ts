import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  amountInWordsAr,
  CONTRACT_TEMPLATE_FORBIDDEN_WORDS,
  CONTRACT_TEMPLATE_PLACEHOLDERS,
  checkContractTemplate,
  ContractDocumentPrintBody,
  DEFAULT_CONTRACT_TERMS_AR,
  renderContractTemplate,
  ShopSettingsUpdateBody,
} from './index.js';

const END = ' فقط لا غير';

describe('amountInWordsAr', () => {
  const cases: [string, string][] = [
    ['0', 'صفر جنيه'],
    ['0.01', 'قرش واحد'],
    ['0.02', 'قرشان'],
    ['0.03', 'ثلاثة قروش'],
    ['0.10', 'عشرة قروش'],
    ['0.11', 'أحد عشر قرشًا'],
    ['0.25', 'خمسة وعشرون قرشًا'],
    ['0.50', 'خمسون قرشًا'],
    ['0.99', 'تسعة وتسعون قرشًا'],
    ['1', 'جنيه واحد'],
    ['2', 'جنيهان'],
    ['3', 'ثلاثة جنيهات'],
    ['10', 'عشرة جنيهات'],
    ['11', 'أحد عشر جنيهًا'],
    ['12', 'اثنا عشر جنيهًا'],
    ['20', 'عشرون جنيهًا'],
    ['21', 'واحد وعشرون جنيهًا'],
    ['22', 'اثنان وعشرون جنيهًا'],
    ['99', 'تسعة وتسعون جنيهًا'],
    ['100', 'مائة جنيه'],
    ['101', 'مائة وجنيه واحد'],
    ['102', 'مائة وجنيهان'],
    ['103', 'مائة وثلاثة جنيهات'],
    ['111', 'مائة وأحد عشر جنيهًا'],
    ['200', 'مائتا جنيه'],
    ['201', 'مائتان وجنيه واحد'],
    ['300', 'ثلاثمائة جنيه'],
    ['999', 'تسعمائة وتسعة وتسعون جنيهًا'],
    ['1000', 'ألف جنيه'],
    ['1001', 'ألف وجنيه واحد'],
    ['1002', 'ألف وجنيهان'],
    ['1100', 'ألف ومائة جنيه'],
    ['1200', 'ألف ومائتا جنيه'],
    ['1250', 'ألف ومائتان وخمسون جنيهًا'],
    ['1250.50', 'ألف ومائتان وخمسون جنيهًا وخمسون قرشًا'],
    ['2000', 'ألفا جنيه'],
    ['2500', 'ألفان وخمسمائة جنيه'],
    ['3000', 'ثلاثة آلاف جنيه'],
    ['10000', 'عشرة آلاف جنيه'],
    ['11000', 'أحد عشر ألف جنيه'],
    ['11500', 'أحد عشر ألفًا وخمسمائة جنيه'],
    ['12.50', 'اثنا عشر جنيهًا وخمسون قرشًا'],
    ['100000', 'مائة ألف جنيه'],
    ['101000', 'مائة وألف جنيه'],
    ['200000', 'مائتا ألف جنيه'],
    ['250000', 'مائتان وخمسون ألف جنيه'],
    ['1000000', 'مليون جنيه'],
    ['1000001', 'مليون وجنيه واحد'],
    ['1500000', 'مليون وخمسمائة ألف جنيه'],
    ['2000000', 'مليونا جنيه'],
    ['2500000', 'مليونان وخمسمائة ألف جنيه'],
    ['3000000', 'ثلاثة ملايين جنيه'],
    ['1250000.75', 'مليون ومائتان وخمسون ألف جنيه وخمسة وسبعون قرشًا'],
    ['1000000000', 'مليار جنيه'],
    [
      '999999999999.99',
      'تسعمائة وتسعة وتسعون مليارًا وتسعمائة وتسعة وتسعون مليونًا وتسعمائة وتسعة وتسعون ألفًا وتسعمائة وتسعة وتسعون جنيهًا وتسعة وتسعون قرشًا',
    ],
  ];

  it.each(cases)('%s', (amount, words) => {
    expect(amountInWordsAr(amount)).toBe(words + END);
  });

  it('covers at least 40 amounts', () => {
    expect(cases.length).toBeGreaterThanOrEqual(40);
  });

  it('refuses negative and malformed amounts', () => {
    expect(() => amountInWordsAr('-1.00')).toThrow(RangeError);
    expect(() => amountInWordsAr('abc')).toThrow(RangeError);
    expect(() => amountInWordsAr('1000000000000.00')).toThrow(RangeError);
  });

  it('never writes interest or fee wording', () => {
    expect(checkContractTemplate(amountInWordsAr('1234.56')).ok).toBe(true);
  });
});

describe('contract terms template', () => {
  it('the default text passes its own checks and uses only known placeholders', () => {
    expect(checkContractTemplate(DEFAULT_CONTRACT_TERMS_AR)).toEqual({
      ok: true,
      unknown: [],
      words: [],
    });
  });

  it('refuses an unknown placeholder', () => {
    expect(checkContractTemplate('Hello {{customer_nam}} and {{ shop_name }}')).toEqual({
      ok: false,
      unknown: ['customer_nam'],
      words: [],
    });
  });

  it('refuses forbidden wording, with or without diacritics, in any case', () => {
    expect(checkContractTemplate('على فائدة شهرية').words).toEqual(['فائدة']);
    expect(checkContractTemplate('على فَائِدَة').words).toEqual(['فائدة']);
    expect(checkContractTemplate('A Late Fee applies').words).toEqual(['late fee']);
    expect(checkContractTemplate('غرامة تأخير').words).toEqual(['غرامة', 'غرامة تأخير']);
    expect(checkContractTemplate('خصم السداد المبكر').ok).toBe(false);
  });

  it('every forbidden word is refused on its own', () => {
    for (const word of CONTRACT_TEMPLATE_FORBIDDEN_WORDS) {
      expect(checkContractTemplate(`نص ${word} نص`).ok).toBe(false);
    }
  });

  it('renders placeholders; a missing value prints empty', () => {
    expect(
      renderContractTemplate('العميل {{ customer_name }} رقم {{contract_number}}{{city}}', {
        customer_name: 'أحمد',
        contract_number: 'C-1',
      }),
    ).toBe('العميل أحمد رقم C-1');
  });

  it('lists 16 placeholders', () => {
    expect(CONTRACT_TEMPLATE_PLACEHOLDERS).toHaveLength(16);
  });
});

describe('bodies', () => {
  it('print body is strict', () => {
    expect(ContractDocumentPrintBody.safeParse({ document: 'contract' }).success).toBe(true);
    expect(ContractDocumentPrintBody.safeParse({ document: 'receipt' }).success).toBe(false);
    expect(ContractDocumentPrintBody.safeParse({ document: 'contract', x: 1 }).success).toBe(false);
  });

  it('settings accept the two new fields', () => {
    expect(
      ShopSettingsUpdateBody.safeParse({ promissory_notes_mode: 'single', contract_terms: null })
        .success,
    ).toBe(true);
    expect(ShopSettingsUpdateBody.safeParse({ promissory_notes_mode: 'many' }).success).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ contract_terms: 'x'.repeat(20001) }).success).toBe(
      false,
    );
  });
});

describe('the migration holds the same lists', () => {
  const dir = resolve(dirname(fileURLToPath(import.meta.url)), '../../../supabase/migrations');
  const sql = readFileSync(resolve(dir, '20261023090000_n07_printed_documents.sql'), 'utf8');
  const quoted = (block: string) => [...block.matchAll(/'([^']+)'/g)].map((m) => m[1]);

  it('forbidden words', () => {
    const block =
      /forbidden\(ord, word\) AS \(\s*VALUES([\s\S]*?)\), found AS/.exec(sql)?.[1] ?? '';
    expect(block.length).toBeGreaterThan(0);
    expect(quoted(block)).toEqual([...CONTRACT_TEMPLATE_FORBIDDEN_WORDS]);
  });

  it('placeholders', () => {
    const block = /placeholders\(name\) AS \(\s*VALUES([\s\S]*?)\), forbidden/.exec(sql)?.[1] ?? '';
    expect(quoted(block)).toEqual([...CONTRACT_TEMPLATE_PLACEHOLDERS]);
  });
});
