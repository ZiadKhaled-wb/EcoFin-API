import { describe, it, expect } from 'vitest';
import {
  EGYPT_GOVERNORATE_CODES,
  isValidNationalId,
  maskNationalId,
  normalizeNationalId,
  parseNationalId,
  toAsciiDigits,
} from './nationalId.js';

// The same vectors as supabase/tests/r01_customers_test.sql (app.parse_national_id).
describe('parseNationalId', () => {
  it('reads the birth date, gender and governorate', () => {
    expect(parseNationalId('29001010100015')).toEqual({
      birth_date: '1990-01-01',
      gender: 'male',
      governorate_code: '01',
    });
    expect(parseNationalId('28506152100023')).toEqual({
      birth_date: '1985-06-15',
      gender: 'female',
      governorate_code: '21',
    });
  });

  it('reads century 3, a leap day and a birth outside Egypt', () => {
    expect(parseNationalId('30002290200344')).toEqual({
      birth_date: '2000-02-29',
      gender: 'female',
      governorate_code: '02',
    });
    expect(parseNationalId('29912318800011')?.governorate_code).toBe('88');
  });

  it.each([
    ['century 4', '49001010100015'],
    ['century 1', '19001010100015'],
    ['month 13', '29013010100015'],
    ['month 00', '29000010100015'],
    ['day 00', '29001000100015'],
    ['30 February', '29002300100015'],
    ['29 February of a common year', '20102290100015'],
    ['an unknown governorate (99)', '29001019900015'],
    ['an unknown governorate (05)', '29001010500015'],
    ['13 digits', '2900101010001'],
    ['15 digits', '290010101000155'],
    ['a letter', '2900101010001a'],
    ['nothing', ''],
  ])('refuses %s', (_name, id) => {
    expect(parseNationalId(id)).toBeNull();
    expect(isValidNationalId(id)).toBe(false);
  });

  it('refuses a birth date after today', () => {
    expect(parseNationalId('39901010100015')).toBeNull();
    expect(parseNationalId('30103152700018', '2001-03-14')).toBeNull();
    expect(parseNationalId('30103152700018', '2001-03-15')?.birth_date).toBe('2001-03-15');
  });

  it('does not verify the check digit', () => {
    for (const last of '0123456789') expect(isValidNationalId(`2900101010001${last}`)).toBe(true);
  });

  it('knows the 27 governorates and 88', () => {
    expect(EGYPT_GOVERNORATE_CODES).toHaveLength(28);
    expect(new Set(EGYPT_GOVERNORATE_CODES).size).toBe(28);
  });
});

describe('national ID text helpers', () => {
  it('turns Arabic-Indic and Persian digits into 0-9', () => {
    expect(toAsciiDigits('٠١٢٣٤٥٦٧٨٩')).toBe('0123456789');
    expect(toAsciiDigits('۰۱۹')).toBe('019');
    expect(toAsciiDigits('abc 12')).toBe('abc 12');
  });

  it('normalises as the server stores it', () => {
    expect(normalizeNationalId(' 2900101-0100015 ')).toBe('29001010100015');
    expect(normalizeNationalId('٢٨٥٠٦١٥٢١٠٠٠٢٣')).toBe('28506152100023');
  });

  it('masks all but the last four digits', () => {
    expect(maskNationalId('29001010100015')).toBe('**********0015');
  });
});
