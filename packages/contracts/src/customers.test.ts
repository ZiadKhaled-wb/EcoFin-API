import { describe, it, expect } from 'vitest';
import {
  Customer,
  CustomerCreateBody,
  CustomerIdParams,
  CustomerList,
  CustomerListQuery,
  CustomerNationalIdTakenDetail,
  CustomerStatusBody,
  CustomerUpdateBody,
  normalizeCustomerPhone,
} from './customers.js';
import { errorCodeHttpStatus } from './errors.js';

const customer = {
  id: 'a0630000-0000-4000-8000-000000000001',
  full_name: 'Ahmed Ali Hassan',
  phones: ['01001234567', '0223456789'],
  national_id: null,
  national_id_masked: '**********0015',
  birth_date: '1990-01-01',
  gender: 'male',
  governorate_code: '01',
  address: '12 Tahrir St',
  city: 'Cairo',
  job: null,
  employer: null,
  monthly_income: '8500.50',
  is_business: false,
  tax_registration_no: null,
  status: 'active',
  notes: null,
  id_photos_count: 2,
  created_at: '2026-10-12T08:00:00.000Z',
  updated_at: '2026-10-12T08:00:00.000Z',
};

describe('normalizeCustomerPhone', () => {
  it('stores an Egyptian mobile as 01XXXXXXXXX however it is written', () => {
    for (const written of [
      ' +20 100 123 4567 ',
      '0020-100-1234567',
      '201001234567',
      '1001234567',
      '0100.123.4567',
      '٠١٠٠١٢٣٤٥٦٧',
    ])
      expect(normalizeCustomerPhone(written)).toBe('01001234567');
  });

  it('keeps the digits of landlines and foreign numbers', () => {
    expect(normalizeCustomerPhone('(02) 2345-6789')).toBe('0223456789');
    expect(normalizeCustomerPhone('+966 50 123 4567')).toBe('+966501234567');
  });
});

describe('CustomerCreateBody', () => {
  it('trims, joins spaces and normalises the phones and the ID', () => {
    expect(
      CustomerCreateBody.parse({
        full_name: '  Ahmed   Ali  Hassan ',
        phones: [' +20 100 123 4567 ', '02-2345 6789'],
        national_id: ' 2900101-0100015 ',
        address: ' 12 Tahrir St ',
        monthly_income: '8500.5',
        notes: '',
      }),
    ).toEqual({
      full_name: 'Ahmed Ali Hassan',
      phones: ['01001234567', '0223456789'],
      national_id: '29001010100015',
      address: '12 Tahrir St',
      monthly_income: '8500.5',
      is_business: false,
      notes: null,
    });
  });

  it('needs a name and at least one phone', () => {
    expect(CustomerCreateBody.safeParse({ phones: ['01001234567'] }).success).toBe(false);
    expect(CustomerCreateBody.safeParse({ full_name: 'Mona Said' }).success).toBe(false);
    expect(CustomerCreateBody.safeParse({ full_name: 'Mona Said', phones: [] }).success).toBe(
      false,
    );
    expect(
      CustomerCreateBody.safeParse({ full_name: ' A ', phones: ['01001234567'] }).success,
    ).toBe(false);
  });

  it('refuses bad phones, repeats and more than five', () => {
    const body = (phones: unknown) => CustomerCreateBody.safeParse({ full_name: 'Mona', phones });
    expect(body(['0100ab00001']).success).toBe(false);
    expect(body(['123456']).success).toBe(false);
    expect(body(['01000000001', '+20 100 000 0001']).success).toBe(false);
    expect(body(['1', '2', '3', '4', '5', '6'].map((n) => `0100000000${n}`)).success).toBe(false);
    expect(body('01000000001').success).toBe(false);
  });

  it('refuses a national ID that does not parse; empty means none', () => {
    const body = (national_id: unknown) =>
      CustomerCreateBody.safeParse({ full_name: 'Mona', phones: ['01000000001'], national_id });
    expect(body('49001010100015').success).toBe(false);
    expect(body('29002300100015').success).toBe(false);
    expect(body('2900101010001').success).toBe(false);
    expect(body('').data?.national_id).toBeNull();
    expect(body(null).data?.national_id).toBeNull();
    expect(body('٢٨٥٠٦١٥٢١٠٠٠٢٣').data?.national_id).toBe('28506152100023');
  });

  it('checks income and the tax number; birth date and gender are not inputs', () => {
    const body = (extra: object) =>
      CustomerCreateBody.safeParse({ full_name: 'Mona', phones: ['01000000001'], ...extra });
    expect(body({ monthly_income: '-5' }).success).toBe(false);
    expect(body({ monthly_income: '100.125' }).success).toBe(false);
    expect(body({ monthly_income: 8500 }).success).toBe(false);
    expect(body({ birth_date: '1988-03-04' }).success).toBe(false);
    expect(body({ gender: 'female' }).success).toBe(false);
    expect(body({ tax_registration_no: '12-34' }).success).toBe(false);
    expect(body({ national_id: '29001010100015' }).success).toBe(true);
  });

  it('a business customer needs a tax number', () => {
    const body = (extra: object) =>
      CustomerCreateBody.safeParse({ full_name: 'Delta LLC', phones: ['0235556667'], ...extra });
    expect(body({ is_business: true }).success).toBe(false);
    expect(body({ is_business: true, tax_registration_no: '' }).success).toBe(false);
    expect(body({ is_business: true, tax_registration_no: '123-456-789' }).success).toBe(true);
  });

  it('is strict: no status, credit limit or organization id', () => {
    for (const extra of [
      { status: 'blocked' },
      { credit_limit: '5000' },
      { organization_id: customer.id },
    ])
      expect(
        CustomerCreateBody.safeParse({ full_name: 'Mona', phones: ['01000000001'], ...extra })
          .success,
      ).toBe(false);
  });
});

describe('CustomerUpdateBody', () => {
  it('takes any field alone and refuses an empty change', () => {
    expect(CustomerUpdateBody.parse({ notes: ' vip ' })).toEqual({ notes: 'vip' });
    expect(CustomerUpdateBody.parse({ national_id: null })).toEqual({ national_id: null });
    expect(CustomerUpdateBody.safeParse({}).success).toBe(false);
    expect(CustomerUpdateBody.safeParse({ status: 'blocked' }).success).toBe(false);
  });
});

describe('CustomerStatusBody', () => {
  it('blocking needs a reason; unblocking does not', () => {
    expect(CustomerStatusBody.safeParse({ status: 'blocked' }).success).toBe(false);
    expect(CustomerStatusBody.safeParse({ status: 'blocked', reason: ' no ' }).success).toBe(false);
    expect(CustomerStatusBody.parse({ status: 'blocked', reason: ' bounced cheques ' })).toEqual({
      status: 'blocked',
      reason: 'bounced cheques',
    });
    expect(CustomerStatusBody.parse({ status: 'active' })).toEqual({ status: 'active' });
  });

  it('watch can not be set by hand', () => {
    expect(CustomerStatusBody.safeParse({ status: 'watch', reason: 'late twice' }).success).toBe(
      false,
    );
  });
});

describe('Customer shapes', () => {
  it('parses a masked customer, a list and the id params', () => {
    expect(Customer.parse(customer)).toEqual(customer);
    expect(
      Customer.parse({ ...customer, national_id: '29001010100015', status: 'watch' }).status,
    ).toBe('watch');
    expect(
      CustomerList.parse({ items: [customer], page: 1, pageSize: 50, total: 1 }).items,
    ).toHaveLength(1);
    expect(CustomerIdParams.safeParse({ id: 'nope' }).success).toBe(false);
  });

  it('list query: defaults, coercion and strictness', () => {
    expect(CustomerListQuery.parse({})).toEqual({ page: 1, pageSize: 50, status: 'all' });
    expect(CustomerListQuery.parse({ search: '  ahmed ', status: 'blocked', page: '2' })).toEqual({
      search: 'ahmed',
      status: 'blocked',
      page: 2,
      pageSize: 50,
    });
    expect(CustomerListQuery.parse({ search: '   ' }).search).toBeUndefined();
    expect(CustomerListQuery.safeParse({ status: 'archived' }).success).toBe(false);
    expect(CustomerListQuery.safeParse({ organization_id: customer.id }).success).toBe(false);
  });

  it('the duplicate-ID detail and the error codes', () => {
    expect(
      CustomerNationalIdTakenDetail.parse({ customer_id: customer.id, full_name: 'Ahmed' }),
    ).toEqual({ customer_id: customer.id, full_name: 'Ahmed' });
    expect(errorCodeHttpStatus.CUSTOMER_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.CUSTOMER_NATIONAL_ID_TAKEN).toBe(409);
  });
});
