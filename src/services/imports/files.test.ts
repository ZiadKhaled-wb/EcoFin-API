import ExcelJS from 'exceljs';
import { describe, expect, it } from 'vitest';
import { IMPORT_COLUMNS, IMPORT_KINDS, suggestImportMapping } from '@ziadkhaled-wb/contracts';
import { buildErrorsCsv, buildImportTemplate, safeCsvCell } from './files';
import { readImportTable, toFieldRows } from './parse';

describe('M01 files: the template', () => {
  it('a csv template is UTF-8 with a BOM: the field keys, then the Arabic labels', async () => {
    const file = await buildImportTemplate('products', 'csv');
    expect(file.filename).toBe('ecofin-import-products-template.csv');
    expect(file.contentType).toContain('text/csv');
    const text = file.body.toString('utf8');
    expect(text.startsWith('\ufeff')).toBe(true);
    const [keys, labels] = text.slice(1).split('\r\n');
    expect(keys).toBe(IMPORT_COLUMNS.products.map((c) => c.key).join(','));
    expect(labels).toContain('سعر النقد *');
  });

  it('every kind template, read back by the importer, maps every column and has no data rows', async () => {
    for (const kind of IMPORT_KINDS) {
      for (const format of ['csv', 'xlsx'] as const) {
        const file = await buildImportTemplate(kind, format);
        const table = await readImportTable(file.body);
        expect(table.headers).toEqual(IMPORT_COLUMNS[kind].map((c) => c.key));
        const { mapping, unmapped_headers } = suggestImportMapping(kind, table.headers);
        expect(Object.keys(mapping)).toHaveLength(IMPORT_COLUMNS[kind].length);
        expect(unmapped_headers).toEqual([]);
        // The Arabic label row is not data.
        expect(toFieldRows(kind, table, mapping)).toEqual([]);
      }
    }
  });

  it('the xlsx has a Template sheet and a Help sheet that explains each column', async () => {
    const file = await buildImportTemplate('opening_stock', 'xlsx');
    expect(file.filename).toBe('ecofin-import-opening-stock-template.xlsx');
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(file.body as unknown as ExcelJS.Buffer);
    expect(wb.worksheets.map((w) => w.name)).toEqual(['Template', 'Help']);
    const help = wb.getWorksheet('Help');
    expect(help?.rowCount).toBe(IMPORT_COLUMNS.opening_stock.length + 1);
    expect(help?.getRow(2).getCell(1).value).toBe('sku');
  });
});

describe('M01 files: the errors CSV', () => {
  it('has a BOM, a header and one line per error; formulas and commas are made safe', () => {
    const csv = buildErrorsCsv([
      { row: 3, column: 'name_ar', code: 'IMPORT_REQUIRED', message: 'a name is required' },
      { row: 7, column: null, code: 'IMPORT_APPLY_FAILED', message: '=HYPERLINK("x"), bad' },
    ]).toString('utf8');
    expect(csv.startsWith('\ufeffrow,column,code,message\r\n')).toBe(true);
    expect(csv).toContain('3,name_ar,IMPORT_REQUIRED,a name is required');
    expect(csv).toContain(`7,,IMPORT_APPLY_FAILED,"'=HYPERLINK(""x""), bad"`);
  });

  it('safeCsvCell prefixes = + - @ and tab', () => {
    expect(safeCsvCell('=1+1')).toBe(`'=1+1`);
    expect(safeCsvCell('+20')).toBe(`'+20`);
    expect(safeCsvCell('-5')).toBe(`'-5`);
    expect(safeCsvCell('@x')).toBe(`'@x`);
    expect(safeCsvCell('plain')).toBe('plain');
    expect(safeCsvCell('a,b')).toBe('"a,b"');
  });
});
