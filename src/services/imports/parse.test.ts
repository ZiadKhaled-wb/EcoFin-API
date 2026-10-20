import ExcelJS from 'exceljs';
import { describe, expect, it } from 'vitest';
import { IMPORT_MAX_ROWS, suggestImportMapping } from '@ziadkhaled-wb/contracts';
import {
  assertSafeZip,
  cleanCell,
  detectImportFileType,
  readImportTable,
  toFieldRows,
  unusedHeaders,
} from './parse';

const csv = (text: string): Buffer => Buffer.from(text, 'utf8');

async function xlsx(build: (wb: ExcelJS.Workbook) => void): Promise<Buffer> {
  const wb = new ExcelJS.Workbook();
  build(wb);
  return Buffer.from(await wb.xlsx.writeBuffer());
}

async function code(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (e) {
    return (e as { code?: string }).code ?? String(e);
  }
  return 'NO_ERROR';
}

describe('M01 parse: CSV', () => {
  it('reads quoted commas, quotes and new lines inside a cell, and numbers rows like Excel', async () => {
    const t = await readImportTable(
      csv('sku,name_ar,cash_price\r\nA1,"Phone, ""big""\nsecond line",100\r\n\r\nA2,Cable,5\r\n'),
    );
    expect(t.fileType).toBe('csv');
    expect(t.headers).toEqual(['sku', 'name_ar', 'cash_price']);
    expect(t.rows.map((r) => r.row)).toEqual([2, 4]); // the empty line is row 3 for Excel
    expect(t.rows[0]?.cells).toEqual(['A1', 'Phone, "big"\nsecond line', '100']);
  });

  it('accepts a UTF-8 BOM, a semicolon delimiter and Arabic headers', async () => {
    const t = await readImportTable(csv('\ufeffكود الصنف;اسم الصنف;السعر\n1;كابل;٥٠\n'));
    expect(t.headers).toEqual(['كود الصنف', 'اسم الصنف', 'السعر']);
    expect(t.rows[0]?.cells).toEqual(['1', 'كابل', '٥٠']);
    const m = suggestImportMapping('products', t.headers);
    expect(m.mapping).toEqual({ sku: 'كود الصنف', name_ar: 'اسم الصنف', cash_price: 'السعر' });
    const rows = toFieldRows('products', t, m.mapping);
    expect(rows).toEqual([{ row: 2, values: { sku: '1', name_ar: 'كابل', cash_price: '50' } }]);
  });

  it('reads the Windows-1256 CSV that Arabic Excel saves', async () => {
    const bytes = Buffer.concat([
      Buffer.from('name,phone\n', 'latin1'),
      Buffer.from([0xc7, 0xcd, 0xe3, 0xcf]), // أحمد in Windows-1256
      Buffer.from(',0101\n', 'latin1'),
    ]);
    const t = await readImportTable(bytes);
    expect(t.rows[0]?.cells[0]).toBe('احمد');
  });

  it('reads UTF-16 text saved by Excel as "Unicode text"', async () => {
    const bytes = Buffer.concat([
      Buffer.from([0xff, 0xfe]),
      Buffer.from('name\tphone\nعلي\t010\n', 'utf16le'),
    ]);
    const t = await readImportTable(bytes);
    expect(t.headers).toEqual(['name', 'phone']);
    expect(t.rows[0]?.cells).toEqual(['علي', '010']);
  });

  it('removes invisible characters and turns non-breaking spaces into spaces', () => {
    expect(cleanCell('\u200fأحمد\u00a0علي\u200b ')).toBe('أحمد علي');
  });

  it('stops at the row limit without reading the rest', async () => {
    const lines = ['name'];
    for (let i = 0; i < IMPORT_MAX_ROWS + 1; i++) lines.push(`n${i}`);
    expect(await code(readImportTable(csv(lines.join('\n'))))).toBe('IMPORT_TOO_MANY_ROWS');
    lines.pop();
    expect((await readImportTable(csv(lines.join('\n')))).rows).toHaveLength(IMPORT_MAX_ROWS);
  });

  it('empty lines do not count towards the limit', async () => {
    const text = 'name\n' + '\n'.repeat(20000) + 'x\n';
    const t = await readImportTable(csv(text));
    expect(t.rows).toHaveLength(1);
    expect(t.rows[0]?.row).toBe(20002);
  });

  it('refuses what is not a table: an exe named .csv, binary noise, an empty file, a bad quote', async () => {
    const exe = Buffer.concat([
      Buffer.from('MZ'),
      Buffer.alloc(200, 0x90),
      Buffer.from('This program'),
    ]);
    expect(detectImportFileType(exe)).toBeNull();
    expect(await code(readImportTable(exe))).toBe('IMPORT_FILE_UNREADABLE');
    expect(await code(readImportTable(Buffer.from([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])))).toBe(
      'IMPORT_FILE_UNREADABLE',
    );
    expect(await code(readImportTable(Buffer.alloc(0)))).toBe('IMPORT_FILE_UNREADABLE');
    expect(await code(readImportTable(csv('a,b\n"open,1\n')))).toBe('IMPORT_FILE_UNREADABLE');
    expect(await code(readImportTable(csv('\n\n  \n')))).toBe('IMPORT_FILE_UNREADABLE');
    // A password-protected workbook is an OLE container, not a zip.
    const ole = Buffer.concat([
      Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
      Buffer.alloc(64),
    ]);
    expect(await code(readImportTable(ole))).toBe('IMPORT_FILE_UNREADABLE');
  });

  it('a CSV has no sheets', async () => {
    expect(await code(readImportTable(csv('a\n1\n'), { sheet: 'Sheet1' }))).toBe(
      'IMPORT_SHEET_NOT_FOUND',
    );
  });
});

describe('M01 parse: XLSX', () => {
  it('reads text, numbers, dates, booleans, formulas and rich text as text', async () => {
    const bytes = await xlsx((wb) => {
      const ws = wb.addWorksheet('Products');
      ws.addRow(['sku', 'name_ar', 'cash_price', 'when', 'flag', 'calc', 'rich']);
      ws.addRow([
        'A1',
        'هاتف',
        1500.5,
        new Date(Date.UTC(2026, 9, 18)),
        true,
        { formula: 'A2&"x"', result: 'A1x' },
        { richText: [{ text: 'Hel' }, { text: 'lo' }] },
      ]);
      ws.addRow(['A2', 'كابل', 5, null, false, { formula: '1+1', result: 2 }, null]);
    });
    const t = await readImportTable(bytes);
    expect(t.fileType).toBe('xlsx');
    expect(t.sheets).toEqual(['Products']);
    expect(t.sheet).toBe('Products');
    expect(t.rows[0]).toEqual({
      row: 2,
      cells: ['A1', 'هاتف', '1500.5', '2026-10-18', 'true', 'A1x', 'Hello'],
    });
    expect(t.rows[1]?.cells).toEqual(['A2', 'كابل', '5', '', 'false', '2', '']);
  });

  it('reads the chosen sheet by name and refuses an unknown one', async () => {
    const bytes = await xlsx((wb) => {
      wb.addWorksheet('Readme').addRow(['hello']);
      const ws = wb.addWorksheet('Data');
      ws.addRow(['name']);
      ws.addRow(['x']);
    });
    expect((await readImportTable(bytes)).sheet).toBe('Readme');
    const t = await readImportTable(bytes, { sheet: 'Data' });
    expect(t.rows).toHaveLength(1);
    expect(t.sheets).toEqual(['Readme', 'Data']);
    expect(await code(readImportTable(bytes, { sheet: 'Nope' }))).toBe('IMPORT_SHEET_NOT_FOUND');
  });

  it('skips empty rows but keeps the real row numbers; a lone row far down is cheap', async () => {
    const bytes = await xlsx((wb) => {
      const ws = wb.addWorksheet('S');
      ws.addRow(['name']);
      ws.getRow(5).values = ['five'];
      ws.getRow(1_048_576).values = ['last'];
    });
    const t = await readImportTable(bytes);
    expect(t.rows.map((r) => r.row)).toEqual([5, 1_048_576]);
  });

  it('stops at the row limit', async () => {
    const bytes = await xlsx((wb) => {
      const ws = wb.addWorksheet('S');
      ws.addRow(['name']);
      for (let i = 0; i < IMPORT_MAX_ROWS + 1; i++) ws.addRow([`n${i}`]);
    });
    expect(await code(readImportTable(bytes))).toBe('IMPORT_TOO_MANY_ROWS');
  });

  it('refuses a zip that is not a workbook and a zip that claims to expand too far', async () => {
    const notBook = Buffer.concat([Buffer.from([0x50, 0x4b, 0x03, 0x04]), Buffer.alloc(100, 1)]);
    expect(await code(readImportTable(notBook))).toBe('IMPORT_FILE_UNREADABLE');

    const bytes = await xlsx((wb) => wb.addWorksheet('S').addRow(['a']));
    expect(() => assertSafeZip(bytes)).not.toThrow();
    // Patch the first central-directory entry to say it expands to 4 GB minus one.
    const bomb = Buffer.from(bytes);
    const eocd = bomb.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
    const cd = bomb.readUInt32LE(eocd + 16);
    bomb.writeUInt32LE(0xfffffff0, cd + 24);
    expect(() => assertSafeZip(bomb)).toThrow();
    expect(await code(readImportTable(bomb))).toBe('IMPORT_FILE_UNREADABLE');
  });

  it('template rows: the Arabic label row is skipped, unmapped headers are listed', async () => {
    const bytes = await xlsx((wb) => {
      const ws = wb.addWorksheet('Template');
      ws.addRow(['sku', 'name_ar', 'cash_price', 'Brand']);
      ws.addRow(['كود الصنف', 'اسم الصنف بالعربية', 'سعر النقد', '']);
      ws.addRow(['A1', 'هاتف', '9000', 'Samsung']);
    });
    const t = await readImportTable(bytes);
    const { mapping } = suggestImportMapping('products', t.headers);
    expect(toFieldRows('products', t, mapping)).toEqual([
      { row: 3, values: { sku: 'A1', name_ar: 'هاتف', cash_price: '9000' } },
    ]);
    expect(unusedHeaders(t, mapping)).toEqual(['Brand']);
  });
});
