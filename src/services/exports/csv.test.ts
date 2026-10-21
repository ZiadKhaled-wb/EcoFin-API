import { describe, expect, it } from 'vitest';
import { parseCsv, unguardCell } from '../../../scripts/export-restore-check.mjs';
import { compactJson, csvHeader, csvLine, exportCell } from './csv';

describe('export CSV cells (M03)', () => {
  it('writes a NULL as an empty cell and leaves plain numbers alone', () => {
    expect(exportCell(null)).toBe('');
    expect(exportCell('-5.00')).toBe('-5.00');
    expect(exportCell('120')).toBe('120');
    expect(exportCell('0.10')).toBe('0.10');
  });

  it('puts a quote in front of every text that Excel could run as a formula', () => {
    expect(exportCell('=1+1')).toBe("'=1+1");
    expect(exportCell('+20100')).toBe("'+20100");
    expect(exportCell('-cmd')).toBe("'-cmd");
    expect(exportCell('@SUM(A1)')).toBe("'@SUM(A1)");
    expect(exportCell('\tx')).toBe("'\tx");
    expect(exportCell('safe')).toBe('safe');
  });

  it('quotes cells with commas, quotes and line breaks, and keeps Arabic', () => {
    expect(exportCell('a,b')).toBe('"a,b"');
    expect(exportCell('say "hi"')).toBe('"say ""hi"""');
    expect(exportCell('line1\nline2')).toBe('"line1\nline2"');
    expect(exportCell('هاتف ذكي')).toBe('هاتف ذكي');
  });

  it('starts the file with a BOM and ends every line with CRLF', () => {
    expect(csvHeader(['id', 'name']).charCodeAt(0)).toBe(0xfeff);
    expect(csvHeader(['id', 'name'])).toBe('﻿id,name\r\n');
    expect(csvLine(['1', null, 'x'], new Set())).toBe('1,,x\r\n');
  });

  it('writes jsonb and array cells as compact JSON text', () => {
    expect(compactJson('{"a": 1, "b": [1, 2]}')).toBe('{"a":1,"b":[1,2]}');
    expect(compactJson('["010", "011"]')).toBe('["010","011"]');
    expect(compactJson('not json')).toBe('not json');
    expect(csvLine(['id', '["010", "011"]'], new Set([1]))).toBe('id,"[""010"",""011""]"\r\n');
  });

  it('reads back what it wrote: parseCsv and unguardCell are the inverse', () => {
    const cells = ['id-1', '=1+1', 'a,b', 'say "hi"', 'line1\nline2', '', '-7.50', 'هاتف'];
    const text =
      csvHeader(['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8']) + csvLine(cells, new Set());
    const rows = parseCsv(text);
    expect(rows[0]).toEqual(['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8']);
    expect((rows[1] ?? []).map(unguardCell)).toEqual(cells);
  });
});
