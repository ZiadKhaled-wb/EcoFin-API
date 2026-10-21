// server/src/services/exports/csv.ts
//
// M03 (D86): the cells of the full export's CSV files. Same rules as M01's writer (UTF-8 BOM, CRLF,
// a text cell that starts with = + - @ tab or CR gets a ' in front so Excel never runs it), with two
// differences that are the export's own: a NULL is an empty cell, and a plain number such as -5.00
// is left alone (a number is not a formula, and the restore check must read amounts back exactly).
// jsonb and array columns are written as compact JSON text.

import { safeCsvCell } from '../imports/files';

export const CSV_BOM = '﻿';

const PLAIN_NUMBER = /^-?\d+(\.\d+)?$/;

/** One cell: null is empty, a plain number is as it is, any other text goes through the formula guard. */
export function exportCell(value: string | null): string {
  if (value === null) return '';
  if (PLAIN_NUMBER.test(value)) return value;
  return safeCsvCell(value);
}

/** The database prints jsonb with spaces ({"a": 1}); the CSV carries it compact. Not JSON: as it is. */
export function compactJson(value: string): string {
  try {
    return JSON.stringify(JSON.parse(value));
  } catch {
    return value;
  }
}

/** One CSV line (CRLF at the end). `jsonColumns` are the indexes of cells that hold JSON text. */
export function csvLine(
  cells: readonly (string | null)[],
  jsonColumns: ReadonlySet<number>,
): string {
  return (
    cells
      .map((cell, i) => exportCell(cell !== null && jsonColumns.has(i) ? compactJson(cell) : cell))
      .join(',') + '\r\n'
  );
}

export function csvHeader(columns: readonly string[]): string {
  return CSV_BOM + columns.map((c) => exportCell(c)).join(',') + '\r\n';
}

/** What a person finds when they open the zip: Arabic first, then English. */
export const EXPORT_README = `تصدير بيانات المحل - EcoFin
==========================

المجلدات:
  csv/       ملف CSV لكل جدول (UTF-8 مع BOM ليفتح العربي صحيحا في Excel).
  json/      نفس الجداول بصيغة JSON (قيم كما هي في قاعدة البيانات).
  manifest.json   عدد صفوف كل جدول والإجماليات الرقابية لاسترجاع البيانات والتحقق منها.

الجداول مرتبطة بالمعرفات (id وما ينتهي بـ _id). لا توجد معادلات: أي خلية نصية تبدأ بـ = أو + أو - أو @
تبدأ بعلامة ' حتى لا ينفذها Excel. الأرقام تبقى كما هي. الخلية الفارغة تعني NULL.
أرقام الهوية القومية مخفية إلا إذا طلب المصدّر التصدير الكامل وكان يملك صلاحية عرضها.
الملفات المرفوعة (الشعار، صور الهوية) غير مضمنة: جدول files يسرد بياناتها فقط.
هذا الملف يحذف من المخزن بعد 7 أيام.

Shop data export - EcoFin
=========================

Folders:
  csv/       one CSV per table (UTF-8 with a BOM, so Arabic opens correctly in Excel).
  json/      the same tables as JSON (values exactly as the database holds them).
  manifest.json   row counts per table and control totals, to restore the data and check it.

Tables are linked by ids (id and every column ending in _id). No cell can run a formula: a text cell that
starts with = + - or @ gets a ' in front. Plain numbers are left as they are. An empty cell is NULL.
National IDs are masked unless the person who exported asked for the full export and may see them.
Uploaded files (logo, ID photos) are not included: the files table lists their records only.
This file is removed from storage after 7 days.
`;
