// server/src/services/imports/parse.ts
//
// M01 (D83): turns an uploaded CSV or XLSX file into plain text rows. Nothing here decides whether
// a value is valid or whom a row matches: that is SQL's job (app.import_*), so the dry run and
// the import use the same rules. This module only reads, safely:
//   * the type comes from the bytes (never the name or the client's mime type);
//   * every cell becomes trimmed text (Excel dates as YYYY-MM-DD, formulas as their cached result,
//     nothing is ever run); invisible characters are removed;
//   * a file is refused as soon as it passes a limit (bytes, rows, a zip that expands too far), so
//     a hostile file never gets loaded in full.

import { parse as parseCsv, CsvError } from 'csv-parse/sync';
import ExcelJS from 'exceljs';
import {
  IMPORT_COLUMNS,
  IMPORT_MAX_BYTES,
  IMPORT_MAX_ROWS,
  normalizeImportHeader,
  type ImportColumnDef,
  type ImportKind,
  type ImportMapping,
} from '@ziadkhaled-wb/contracts';
import { AppError, safeMessage } from '../../utils/errors';

/** A zip (xlsx) may expand to this much, in total and per part, and hold this many parts. */
const ZIP_MAX_TOTAL = 40 * 1024 * 1024;
const ZIP_MAX_PART = 30 * 1024 * 1024;
const ZIP_MAX_ENTRIES = 500;
/** Columns read from a file; the rest are cut off (a template has at most 15). */
const MAX_COLUMNS = 100;
const MAX_CELL_CHARS = 5000;

export type ImportFileType = 'csv' | 'xlsx';

export interface FileRow {
  /** The row's number as Excel shows it (the header is usually row 1). */
  row: number;
  /** One text per header, same order and length as `headers`. */
  cells: string[];
}

export interface FileTable {
  fileType: ImportFileType;
  /** Sheet names (xlsx); empty for a CSV. */
  sheets: string[];
  sheet: string | null;
  headers: string[];
  rows: FileRow[];
}

/** A row once its columns carry field keys: `values` holds only the mapped, non-empty fields. */
export interface FieldRow {
  row: number;
  values: Record<string, string>;
}

const unreadable = () =>
  new AppError(safeMessage('IMPORT_FILE_UNREADABLE'), 'IMPORT_FILE_UNREADABLE');
const tooMany = () =>
  new AppError(safeMessage('IMPORT_TOO_MANY_ROWS'), 'IMPORT_TOO_MANY_ROWS', undefined, {
    max: IMPORT_MAX_ROWS,
  });

// ---------------------------------------------------------------------------------------------
// Detecting the type from the bytes

const OLE_MAGIC = Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);
const ZIP_MAGIC = Buffer.from([0x50, 0x4b, 0x03, 0x04]);
const BINARY_MAGICS: readonly Buffer[] = [
  Buffer.from('MZ'),
  Buffer.from([0x7f, 0x45, 0x4c, 0x46]),
  Buffer.from('%PDF'),
  Buffer.from([0x89, 0x50, 0x4e, 0x47]),
  Buffer.from('GIF8'),
  Buffer.from([0xff, 0xd8, 0xff]),
  Buffer.from('RIFF'),
  Buffer.from([0x1f, 0x8b]),
  Buffer.from('Rar!'),
  Buffer.from('7z'),
  Buffer.from('SQLite'),
];

const startsWith = (bytes: Buffer, magic: Buffer): boolean =>
  bytes.length >= magic.length && bytes.subarray(0, magic.length).equals(magic);

export function detectImportFileType(bytes: Buffer): ImportFileType | null {
  if (bytes.length === 0) return null;
  if (startsWith(bytes, ZIP_MAGIC)) return 'xlsx';
  // A password-protected workbook and the old .xls are OLE containers: not readable here.
  if (startsWith(bytes, OLE_MAGIC)) return null;
  if (BINARY_MAGICS.some((m) => startsWith(bytes, m))) return null;
  return decodeText(bytes) === null ? null : 'csv';
}

/** The text of a CSV: UTF-8 (BOM or not), UTF-16 with BOM, else Windows-1256 (Arabic Excel's "CSV"). */
function decodeText(bytes: Buffer): string | null {
  let text: string;
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    text = new TextDecoder('utf-16le').decode(bytes.subarray(2));
  } else if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    text = new TextDecoder('utf-16be').decode(bytes.subarray(2));
  } else {
    if (bytes.includes(0)) return null;
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      text = new TextDecoder('windows-1256').decode(bytes);
    }
  }
  text = text.replace(/^\ufeff/, '');
  // Text has almost no control characters besides tab and line breaks.
  let control = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 32 && c !== 9 && c !== 10 && c !== 13) control++;
  }
  return control > text.length / 100 ? null : text;
}

// ---------------------------------------------------------------------------------------------
// Cell text

const INVISIBLE = /[\u200b-\u200f\u202a-\u202e\u2060\ufeff]/g;

export function cleanCell(value: string): string {
  return value
    .replace(INVISIBLE, '')
    .replace(/[\u00a0\u2007\u202f]/g, ' ')
    .trim()
    .slice(0, MAX_CELL_CHARS);
}

const isoDate = (d: Date): string => d.toISOString().slice(0, 10);

function cellText(value: ExcelJS.CellValue): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return cleanCell(value);
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : '';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? '' : isoDate(value);
  if (typeof value === 'object') {
    if ('result' in value || 'formula' in value || 'sharedFormula' in value) {
      return cellText((value as { result?: ExcelJS.CellValue }).result ?? null);
    }
    if ('richText' in value) return cleanCell(value.richText.map((r) => r.text).join(''));
    if ('error' in value) return cleanCell(String(value.error));
    if ('text' in value) return cleanCell(String(value.text));
  }
  return '';
}

// ---------------------------------------------------------------------------------------------
// A zip's central directory, read before anything is unpacked

/** Throws IMPORT_FILE_UNREADABLE for a zip that would expand too far, or is not a whole zip. */
export function assertSafeZip(bytes: Buffer): void {
  const minEocd = 22;
  const from = Math.max(0, bytes.length - minEocd - 0xffff);
  let eocd = -1;
  for (let i = bytes.length - minEocd; i >= from; i--) {
    if (bytes.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw unreadable();
  const entries = bytes.readUInt16LE(eocd + 10);
  let at = bytes.readUInt32LE(eocd + 16);
  if (entries === 0xffff || at === 0xffffffff || entries > ZIP_MAX_ENTRIES || entries === 0) {
    throw unreadable();
  }
  let total = 0;
  for (let i = 0; i < entries; i++) {
    if (at + 46 > bytes.length || bytes.readUInt32LE(at) !== 0x02014b50) throw unreadable();
    const size = bytes.readUInt32LE(at + 24);
    if (size === 0xffffffff || size > ZIP_MAX_PART) throw unreadable();
    total += size;
    if (total > ZIP_MAX_TOTAL) throw unreadable();
    at +=
      46 + bytes.readUInt16LE(at + 28) + bytes.readUInt16LE(at + 30) + bytes.readUInt16LE(at + 32);
  }
}

// ---------------------------------------------------------------------------------------------
// Reading a table

interface ReadOptions {
  sheet?: string | undefined;
}

/** Reads the file into a header row and data rows (empty rows dropped), within the limits. */
export async function readImportTable(
  bytes: Buffer,
  options: ReadOptions = {},
): Promise<FileTable> {
  if (bytes.length === 0 || bytes.length > IMPORT_MAX_BYTES) throw unreadable();
  const type = detectImportFileType(bytes);
  if (type === null) throw unreadable();
  return type === 'xlsx' ? readXlsx(bytes, options) : readCsv(bytes, options);
}

function guessDelimiter(text: string): string {
  const line = text.split(/\r\n|\n|\r/).find((l) => l.trim() !== '') ?? '';
  const counts = new Map<string, number>([
    [',', 0],
    [';', 0],
    ['\t', 0],
  ]);
  let quoted = false;
  for (const ch of line) {
    if (ch === '"') quoted = !quoted;
    else if (!quoted && counts.has(ch)) counts.set(ch, (counts.get(ch) ?? 0) + 1);
  }
  let best = ',';
  for (const [d, n] of counts) if (n > (counts.get(best) ?? 0)) best = d;
  return best;
}

class RowLimit extends Error {}

function readCsv(bytes: Buffer, options: ReadOptions): FileTable {
  if (options.sheet !== undefined) {
    throw new AppError(safeMessage('IMPORT_SHEET_NOT_FOUND'), 'IMPORT_SHEET_NOT_FOUND');
  }
  const text = decodeText(bytes);
  if (text === null) throw unreadable();
  let recordNo = 0;
  let dataRows = 0;
  const state: { headers: string[] | null } = { headers: null };
  const rows: FileRow[] = [];
  try {
    parseCsv(text, {
      delimiter: guessDelimiter(text),
      relax_column_count: true,
      skip_empty_lines: false,
      max_record_size: 200_000,
      // Each record is handled as it is read, so a huge file never sits in memory as a whole.
      on_record: (record: string[]) => {
        recordNo++;
        const cells = record.map(cleanCell);
        if (cells.every((c) => c === '')) return null;
        if (state.headers === null) {
          state.headers = cells.slice(0, MAX_COLUMNS);
          return null;
        }
        dataRows++;
        if (dataRows > IMPORT_MAX_ROWS) throw new RowLimit();
        const width = state.headers.length;
        rows.push({
          row: recordNo,
          cells: Array.from({ length: width }, (_, i) => cells[i] ?? ''),
        });
        return null;
      },
    });
  } catch (error) {
    if (error instanceof RowLimit) throw tooMany();
    if (error instanceof CsvError) throw unreadable();
    throw error;
  }
  if (state.headers === null) throw unreadable();
  return { fileType: 'csv', sheets: [], sheet: null, headers: state.headers, rows };
}

async function readXlsx(bytes: Buffer, options: ReadOptions): Promise<FileTable> {
  assertSafeZip(bytes);
  const workbook = new ExcelJS.Workbook();
  try {
    // exceljs wants an ArrayBuffer-like input; the copy keeps the original Buffer untouched.
    await workbook.xlsx.load(bytes as unknown as ExcelJS.Buffer);
  } catch {
    throw unreadable();
  }
  const sheets = workbook.worksheets.map((w) => w.name);
  if (sheets.length === 0) throw unreadable();
  let sheet: ExcelJS.Worksheet | undefined;
  if (options.sheet !== undefined) {
    sheet = workbook.worksheets.find((w) => w.name === options.sheet);
    if (sheet === undefined) {
      throw new AppError(safeMessage('IMPORT_SHEET_NOT_FOUND'), 'IMPORT_SHEET_NOT_FOUND');
    }
  } else {
    sheet = workbook.worksheets.find((w) => w.state === 'visible') ?? workbook.worksheets[0];
  }
  if (sheet === undefined) throw unreadable();

  const state: { headers: string[] | null } = { headers: null };
  let dataRows = 0;
  const rows: FileRow[] = [];
  try {
    sheet.eachRow({ includeEmpty: false }, (excelRow, rowNumber) => {
      const width = state.headers?.length ?? Math.min(excelRow.cellCount, MAX_COLUMNS);
      const cells: string[] = [];
      for (let c = 1; c <= width; c++) cells.push(cellText(excelRow.getCell(c).value));
      if (cells.every((c) => c === '')) return;
      if (state.headers === null) {
        // Trailing empty header cells are not columns.
        let end = cells.length;
        while (end > 0 && cells[end - 1] === '') end--;
        state.headers = cells.slice(0, end);
        return;
      }
      dataRows++;
      if (dataRows > IMPORT_MAX_ROWS) throw new RowLimit();
      rows.push({ row: rowNumber, cells });
    });
  } catch (error) {
    if (error instanceof RowLimit) throw tooMany();
    throw error;
  }
  if (state.headers === null) throw unreadable();
  return { fileType: 'xlsx', sheets, sheet: sheet.name, headers: state.headers, rows };
}

// ---------------------------------------------------------------------------------------------
// Header cells → field keys

const ARABIC_INDIC = /[٠-٩۰-۹]/g;
const asciiDigits = (s: string): string =>
  s.replace(ARABIC_INDIC, (d) => String(d.charCodeAt(0) & 0xf));

/** Types whose digits are normalised here (a name or an address keeps its own digits). */
const DIGIT_TYPES: ReadonlySet<ImportColumnDef['type']> = new Set([
  'money',
  'integer',
  'date',
  'phones',
  'national_id',
]);

function fieldNames(def: ImportColumnDef): Set<string> {
  return new Set([def.key, def.label_en, def.label_ar, ...def.aliases].map(normalizeImportHeader));
}

/**
 * Rows with field keys instead of columns. `mapping` is field → header (a missing header is an
 * IMPORT_MAPPING_INVALID for the caller to report; here it is simply not found). A row that only
 * repeats the column titles (the template's Arabic label row) is dropped.
 */
export function toFieldRows(
  kind: ImportKind,
  table: FileTable,
  mapping: ImportMapping,
): FieldRow[] {
  const defs = IMPORT_COLUMNS[kind];
  const used = defs
    .map((def) => ({
      def,
      index: table.headers.indexOf(mapping[def.key] ?? '\u0000'),
      names: fieldNames(def),
    }))
    .filter((f) => f.index >= 0);
  const out: FieldRow[] = [];
  for (const row of table.rows) {
    const values: Record<string, string> = {};
    let titles = true;
    for (const { def, index, names } of used) {
      let value = row.cells[index] ?? '';
      if (value === '') continue;
      if (!names.has(normalizeImportHeader(value))) titles = false;
      if (DIGIT_TYPES.has(def.type)) value = asciiDigits(value);
      values[def.key] = value;
    }
    const filled = Object.keys(values).length;
    if (filled === 0 || titles) continue;
    out.push({ row: row.row, values });
  }
  return out;
}

/** Headers that the mapping does not use (they are ignored and reported as a warning). */
export function unusedHeaders(table: FileTable, mapping: ImportMapping): string[] {
  const taken = new Set(Object.values(mapping));
  return table.headers.filter((h) => h !== '' && !taken.has(h));
}
