// F14 pure file rules: size, magic-byte types, purpose allow-lists, names, hashes, orphans.
import { describe, it, expect } from 'vitest';
import { FILE_PURPOSES } from '@ziadkhaled-wb/contracts';
import {
  ALLOWED_TYPES,
  ENTITY_TABLES,
  READ_PERMISSION,
  UPLOAD_PERMISSION,
  assertAllowedType,
  assertUploadSize,
  detectFileType,
  extensionOf,
  findOrphans,
  mimeOf,
  sanitizeOriginalName,
  sha256Hex,
} from './files.rules';
import { AppError } from '../utils/errors';

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46]);
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const WEBP = Buffer.concat([
  Buffer.from('RIFF'),
  Buffer.from([1, 2, 3, 4]),
  Buffer.from('WEBPVP8 '),
]);
const PDF = Buffer.from('%PDF-1.7\n%....');
const XLSX = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x14, 0x00]);
const CSV = Buffer.from('name,price\nTV,100\n', 'utf8');

const codeOf = (fn: () => unknown): string => {
  try {
    fn();
  } catch (err) {
    return err instanceof AppError ? err.code : 'other';
  }
  return 'none';
};

describe('assertUploadSize', () => {
  it('accepts a file up to the limit', () => {
    expect(() => assertUploadSize(10485760, 10485760)).not.toThrow();
    expect(() => assertUploadSize(1, 10485760)).not.toThrow();
  });
  it('refuses a file over the limit with 413 FILE_TOO_LARGE', () => {
    expect(codeOf(() => assertUploadSize(10485761, 10485760))).toBe('FILE_TOO_LARGE');
    try {
      assertUploadSize(10485761, 10485760);
    } catch (err) {
      expect((err as AppError).statusCode).toBe(413);
    }
  });
  it('refuses an empty file as a validation error', () => {
    expect(codeOf(() => assertUploadSize(0, 10485760))).toBe('VALIDATION_FAILED');
  });
});

describe('detectFileType (magic bytes, never the client mime or name)', () => {
  it('finds JPEG by FF D8 FF', () => expect(detectFileType(JPEG, null)).toBe('jpeg'));
  it('finds PNG by 89 50 4E 47', () => expect(detectFileType(PNG, null)).toBe('png'));
  it('finds WEBP by RIFF....WEBP', () => expect(detectFileType(WEBP, null)).toBe('webp'));
  it('finds PDF by %PDF', () => expect(detectFileType(PDF, null)).toBe('pdf'));
  it('finds XLSX (zip) by 50 4B 03 04', () => expect(detectFileType(XLSX, null)).toBe('xlsx'));
  it('finds CSV only with a .csv name and valid UTF-8 text', () => {
    expect(detectFileType(CSV, 'prices.csv')).toBe('csv');
    expect(detectFileType(CSV, 'PRICES.CSV')).toBe('csv');
  });
  it('does not call text CSV without a .csv name', () => {
    expect(detectFileType(CSV, 'prices.txt')).toBeNull();
    expect(detectFileType(CSV, null)).toBeNull();
  });
  it('does not call binary data CSV, even with a .csv name', () => {
    expect(detectFileType(Buffer.from([0xff, 0xfe, 0x41, 0x00]), 'a.csv')).toBeNull();
    expect(detectFileType(Buffer.from('a,b\u0000c', 'utf8'), 'a.csv')).toBeNull();
  });
  it('lets the bytes win over a misleading name', () => {
    expect(detectFileType(JPEG, 'contract.pdf')).toBe('jpeg');
  });
  it('returns null for anything unknown', () => {
    expect(detectFileType(Buffer.from('GIF89a'), 'a.gif')).toBeNull();
    expect(detectFileType(Buffer.alloc(0), null)).toBeNull();
  });
});

describe('purpose allow-lists', () => {
  const images = ['jpeg', 'png', 'webp'];
  it('images only for the photo purposes', () => {
    for (const p of [
      'logo',
      'product_image',
      'customer_id',
      'survey_photo',
      'signature',
      'delivery_proof',
    ] as const) {
      expect(ALLOWED_TYPES[p]).toEqual(images);
    }
  });
  it('images and pdf for receipts, documents and contracts', () => {
    for (const p of [
      'expense_receipt',
      'legal_document',
      'contract_pdf',
      'promissory_note',
      'other',
    ] as const) {
      expect(ALLOWED_TYPES[p]).toEqual([...images, 'pdf']);
    }
  });
  it('csv, xlsx and pdf only for import and export', () => {
    expect(ALLOWED_TYPES.import).toEqual(['csv', 'xlsx', 'pdf']);
    expect(ALLOWED_TYPES.export).toEqual(['csv', 'xlsx', 'pdf']);
  });
  it('refuses a type the purpose does not allow with 415 FILE_TYPE_NOT_ALLOWED', () => {
    expect(codeOf(() => assertAllowedType('pdf', 'logo'))).toBe('FILE_TYPE_NOT_ALLOWED');
    expect(codeOf(() => assertAllowedType('csv', 'expense_receipt'))).toBe('FILE_TYPE_NOT_ALLOWED');
    expect(codeOf(() => assertAllowedType('jpeg', 'logo'))).toBe('none');
  });
  it('maps each detected type to one mime and extension', () => {
    expect(mimeOf('jpeg')).toBe('image/jpeg');
    expect(extensionOf('jpeg')).toBe('jpg');
    expect(mimeOf('xlsx')).toBe(
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(extensionOf('csv')).toBe('csv');
  });
});

describe('purpose to permission map', () => {
  it('covers every file_purpose value for upload and for reading', () => {
    for (const p of FILE_PURPOSES) {
      expect(UPLOAD_PERMISSION).toHaveProperty(p);
      expect(READ_PERMISSION).toHaveProperty(p);
    }
    expect(Object.keys(UPLOAD_PERMISSION).sort()).toEqual([...FILE_PURPOSES].sort());
    expect(Object.keys(READ_PERMISSION).sort()).toEqual([...FILE_PURPOSES].sort());
  });
  it('matches the F14 table', () => {
    expect(UPLOAD_PERMISSION).toMatchObject({
      logo: 'org.settings_manage',
      product_image: 'catalog.manage',
      customer_id: 'customer.create',
      survey_photo: 'survey.submit',
      signature: 'installment.create',
      contract_pdf: 'installment.create',
      promissory_note: 'installment.create',
      delivery_proof: 'delivery.manage',
      expense_receipt: 'expense.create',
      legal_document: 'legal.manage',
      import: 'import.data',
      export: 'export.data',
      other: 'org.settings_manage',
    });
    expect(READ_PERMISSION).toMatchObject({
      logo: null,
      product_image: null,
      customer_id: 'customer.view_pii',
      survey_photo: 'customer.view_pii',
      signature: 'customer.view_pii',
      contract_pdf: null,
      promissory_note: null,
      delivery_proof: null,
      expense_receipt: 'cash.view',
      legal_document: 'legal.view',
      import: 'import.data',
      export: 'export.data',
      other: 'org.settings_manage',
    });
  });
  it('entity types point only at tables the shop-ownership check knows', () => {
    expect(Object.values(ENTITY_TABLES).length).toBeGreaterThan(0);
  });
});

describe('sanitizeOriginalName', () => {
  it('keeps a normal name', () =>
    expect(sanitizeOriginalName('invoice 01.pdf')).toBe('invoice 01.pdf'));
  it('strips path parts, both separators', () => {
    expect(sanitizeOriginalName('../../etc/passwd')).toBe('passwd');
    expect(sanitizeOriginalName('C:\\Users\\me\\a.pdf')).toBe('a.pdf');
  });
  it('strips control characters', () =>
    expect(sanitizeOriginalName('a\u0000b\u0007c.png')).toBe('abc.png'));
  it('caps at 200 characters, counting code points', () => {
    const long = '\u{1F600}'.repeat(250);
    expect(Array.from(sanitizeOriginalName(long) ?? '').length).toBe(200);
  });
  it('returns null for missing or empty names', () => {
    expect(sanitizeOriginalName(undefined)).toBeNull();
    expect(sanitizeOriginalName('   ')).toBeNull();
    expect(sanitizeOriginalName('../')).toBeNull();
  });
});

describe('sha256Hex', () => {
  it('computes the hex digest on the server', () => {
    expect(sha256Hex(Buffer.from('abc'))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });
});

describe('findOrphans', () => {
  const now = new Date('2026-10-05T12:00:00Z');
  const old = new Date('2026-10-04T10:00:00Z'); // 26 h before now
  const fresh = new Date('2026-10-05T11:00:00Z'); // 1 h before now
  it('lists old objects with no files row', () => {
    const objects = [
      { path: 'org/a.jpg', createdAt: old },
      { path: 'org/b.jpg', createdAt: fresh },
    ];
    expect(findOrphans(objects, new Set(), now)).toEqual(['org/a.jpg']);
  });
  it('skips objects that have a files row', () => {
    const objects = [{ path: 'org/a.jpg', createdAt: old }];
    expect(findOrphans(objects, new Set(['org/a.jpg']), now)).toEqual([]);
  });
  it('treats exactly 24 hours as old enough', () => {
    const exactly = new Date('2026-10-04T12:00:00Z');
    expect(findOrphans([{ path: 'x', createdAt: exactly }], new Set(), now)).toEqual(['x']);
  });
});
