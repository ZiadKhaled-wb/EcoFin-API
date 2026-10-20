// server/src/services/imports/files.ts
//
// M01 (D83): the two files the import API writes. Both come from the contracts' column list
// (IMPORT_COLUMNS), so the template and the parser can never disagree.
//   * the template (xlsx or csv): headers, an Arabic label row the parser skips, and in the xlsx a
//     "Help" sheet that explains each column (required or not, allowed values, an example);
//   * the errors CSV of a failed run: row, column, code, message. UTF-8 with a BOM so Arabic opens
//     right in Excel; a cell that starts with = + - @ is prefixed with ' so Excel never runs it.

import ExcelJS from 'exceljs';
import { IMPORT_COLUMNS, type ImportKind, type ImportRowError } from '@ziadkhaled-wb/contracts';

const BOM = '\ufeff';

/** Makes a text cell safe to open in Excel: a leading formula character gets a quote in front. */
export function safeCsvCell(value: string): string {
  const text = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function csv(rows: readonly (readonly string[])[]): Buffer {
  return Buffer.from(
    BOM + rows.map((r) => r.map(safeCsvCell).join(',')).join('\r\n') + '\r\n',
    'utf8',
  );
}

export interface BuiltFile {
  filename: string;
  contentType: string;
  body: Buffer;
}

const CONTENT_TYPE = {
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  csv: 'text/csv; charset=utf-8',
} as const;

/** The labels row: the Arabic label, marked with * when the column is required. */
function labelRow(kind: ImportKind): string[] {
  return IMPORT_COLUMNS[kind].map((c) =>
    c.required || c.requiredOneOf ? `${c.label_ar} *` : c.label_ar,
  );
}

export async function buildImportTemplate(
  kind: ImportKind,
  format: 'xlsx' | 'csv',
): Promise<BuiltFile> {
  const defs = IMPORT_COLUMNS[kind];
  const filename = `ecofin-import-${kind.replaceAll('_', '-')}-template.${format}`;
  if (format === 'csv') {
    return {
      filename,
      contentType: CONTENT_TYPE.csv,
      body: csv([defs.map((c) => c.key), labelRow(kind)]),
    };
  }
  const wb = new ExcelJS.Workbook();
  wb.creator = 'EcoFin';
  const sheet = wb.addWorksheet('Template', { views: [{ state: 'frozen', ySplit: 2 }] });
  sheet.addRow(defs.map((c) => c.key));
  sheet.addRow(labelRow(kind));
  sheet.getRow(1).font = { bold: true };
  sheet.getRow(2).font = { italic: true, color: { argb: 'FF666666' } };
  defs.forEach((c, i) => {
    sheet.getColumn(i + 1).width = Math.max(14, c.label_ar.length + 4, c.key.length + 4);
  });

  const help = wb.addWorksheet('Help', { views: [{ rightToLeft: true }] });
  help.addRow([
    'Column',
    'العمود',
    'Required',
    'مطلوب',
    'Allowed values',
    'Example',
    'الشرح',
    'Notes',
  ]);
  help.getRow(1).font = { bold: true };
  for (const c of defs) {
    const required = c.required ? 'yes' : c.requiredOneOf ? `one of: ${c.requiredOneOf}` : 'no';
    help.addRow([
      c.key,
      c.label_ar,
      required,
      c.required ? 'نعم' : c.requiredOneOf ? 'أحدهما على الأقل' : 'لا',
      c.allowed ? c.allowed.join(' / ') : '',
      c.example,
      c.help_ar,
      c.help_en,
    ]);
  }
  [18, 22, 14, 16, 22, 24, 50, 50].forEach((w, i) => {
    help.getColumn(i + 1).width = w;
  });
  help.getColumn(7).alignment = { wrapText: true, vertical: 'top' };
  help.getColumn(8).alignment = { wrapText: true, vertical: 'top' };
  const body = Buffer.from(await wb.xlsx.writeBuffer());
  return { filename, contentType: CONTENT_TYPE.xlsx, body };
}

/** The errors of a failed run as a CSV the owner fixes in Excel. */
export function buildErrorsCsv(errors: readonly ImportRowError[]): Buffer {
  return csv([
    ['row', 'column', 'code', 'message'],
    ...errors.map((e) => [String(e.row), e.column ?? '', e.code, e.message]),
  ]);
}
