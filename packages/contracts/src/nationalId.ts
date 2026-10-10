/**
 * Egyptian national ID (14 digits), R01 (D63). Ported from the old CRM parser and tightened:
 *
 *   digit 1       century: 2 = 19xx, 3 = 20xx (nothing else is issued yet)
 *   digits 2-7    birth date, YYMMDD (must be a real calendar date, not in the future)
 *   digits 8-9    governorate of birth (`EGYPT_GOVERNORATE_CODES`)
 *   digits 10-13  serial; digit 13 odd = male, even = female
 *   digit 14      check digit: NOT verified (no official, verifiable algorithm; see OLD_CODE_MAP)
 *
 * The database repeats these rules in `app.parse_national_id` and is the authority on writes; this
 * copy is for request validation and for showing the birth date and gender while typing. Both are
 * tested with the same vectors (`nationalId.test.ts`, `r01_customers_test.sql`).
 */

/** The 27 governorates plus 88 (born outside Egypt). Names live in the client's translations. */
export const EGYPT_GOVERNORATE_CODES = [
  '01', // Cairo
  '02', // Alexandria
  '03', // Port Said
  '04', // Suez
  '11', // Damietta
  '12', // Dakahlia
  '13', // Sharqia
  '14', // Qalyubia
  '15', // Kafr El Sheikh
  '16', // Gharbia
  '17', // Monufia
  '18', // Beheira
  '19', // Ismailia
  '21', // Giza
  '22', // Beni Suef
  '23', // Fayoum
  '24', // Minya
  '25', // Assiut
  '26', // Sohag
  '27', // Qena
  '28', // Aswan
  '29', // Luxor
  '31', // Red Sea
  '32', // New Valley
  '33', // Matrouh
  '34', // North Sinai
  '35', // South Sinai
  '88', // outside Egypt
] as const;
export type EgyptGovernorateCode = (typeof EGYPT_GOVERNORATE_CODES)[number];

export const NATIONAL_ID_LENGTH = 14;

export type NationalIdGender = 'male' | 'female';

export interface ParsedNationalId {
  /** YYYY-MM-DD */
  birth_date: string;
  gender: NationalIdGender;
  governorate_code: EgyptGovernorateCode;
}

const ARABIC_INDIC_ZERO = 0x0660;
const EXTENDED_ARABIC_INDIC_ZERO = 0x06f0;

/** Arabic-Indic (٠-٩) and Persian (۰-۹) digits as 0-9; everything else is left as typed. */
export function toAsciiDigits(value: string): string {
  return value.replace(/[\u0660-\u0669\u06f0-\u06f9]/g, (d) => {
    const code = d.charCodeAt(0);
    return String(
      code - (code >= EXTENDED_ARABIC_INDIC_ZERO ? EXTENDED_ARABIC_INDIC_ZERO : ARABIC_INDIC_ZERO),
    );
  });
}

/** As the server stores it: ASCII digits, spaces and dashes removed. */
export function normalizeNationalId(value: string): string {
  return toAsciiDigits(value).replace(/[\s-]/g, '');
}

const isGovernorateCode = (code: string): code is EgyptGovernorateCode =>
  (EGYPT_GOVERNORATE_CODES as readonly string[]).includes(code);

/**
 * The birth date, gender and governorate of a normalised national ID, or null when it is not a
 * valid one. `today` (YYYY-MM-DD) is the newest birth date accepted; it defaults to tomorrow in
 * UTC so a shop ahead of UTC is never refused.
 */
export function parseNationalId(id: string, today?: string): ParsedNationalId | null {
  if (!/^[0-9]{14}$/.test(id)) return null;
  const century = id[0] === '2' ? 1900 : id[0] === '3' ? 2000 : null;
  if (century === null) return null;

  const year = century + Number(id.slice(1, 3));
  const month = Number(id.slice(3, 5));
  const day = Number(id.slice(5, 7));
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  )
    return null;
  const birth_date = date.toISOString().slice(0, 10);
  const latest = today ?? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  if (birth_date > latest) return null;

  const governorate_code = id.slice(7, 9);
  if (!isGovernorateCode(governorate_code)) return null;

  return { birth_date, gender: Number(id[12]) % 2 === 1 ? 'male' : 'female', governorate_code };
}

export const isValidNationalId = (id: string, today?: string): boolean =>
  parseNationalId(id, today) !== null;

/** What a user without `customer.view_pii` sees: ten stars and the last four digits. */
export function maskNationalId(id: string): string {
  return `${'*'.repeat(NATIONAL_ID_LENGTH - 4)}${id.slice(-4)}`;
}
