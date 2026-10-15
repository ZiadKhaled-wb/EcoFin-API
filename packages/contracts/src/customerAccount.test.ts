import { describe, it, expect } from 'vitest';
import {
  CUSTOMER_STATEMENT_MAX_YEARS,
  CustomerAccount,
  CustomerContractParams,
  CustomerContractSchedule,
  CustomerStatement,
  CustomerStatementQuery,
} from './customerAccount.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0740000-0000-4000-8000-000000000001';
const CUSTOMER = 'a0740000-0000-4000-8000-000000000002';
const CONTRACT = 'a0740000-0000-4000-8000-000000000003';
const AT = '2026-10-16T09:00:00.000Z';

const contractSummary = (extra: Record<string, unknown> = {}) => ({
  id: CONTRACT,
  number: 'BR1-CT-26-000001',
  status: 'active',
  branch: { id: ID, name: 'Main' },
  sale_id: ID,
  sale_number: 'BR1-SL-26-000010',
  issued_at: AT,
  is_migrated: false,
  cash_price: '10000.00',
  down_payment: '0.00',
  financed_amount: '10000.00',
  markup_amount: '2000.00',
  total_payable: '12000.00',
  contract_total: '12000.00',
  paid: '3000.00',
  remaining: '9000.00',
  fees_due: '100.00',
  overdue_amount: '3000.00',
  overdue_lines: 1,
  max_days_late: 5,
  next_due_date: '2026-10-11',
  installments_count: 4,
  frequency: 'monthly',
  first_due_date: '2026-09-16',
  ...extra,
});

const account = (extra: Record<string, unknown> = {}) => ({
  customer: {
    id: CUSTOMER,
    full_name: 'Open Balance Customer',
    status: 'active',
    phones: ['01000000777'],
  },
  balance: {
    contract_totals: '19200.00',
    payments: '3000.00',
    returns: '1200.00',
    open_balance: '15000.00',
    fees_due: '100.00',
    total_due: '15100.00',
    store_credit: '0.00',
    credit_limit: '20000.00',
    available: '6000.00',
  },
  overdue: {
    overdue_amount: '3000.00',
    overdue_lines: 1,
    max_days_late: 5,
    next_due_date: '2026-10-11',
    next_due_amount: '3000.00',
    aging: {
      not_yet_due: '6000.00',
      late_1_30: '3000.00',
      late_31_60: '0.00',
      late_61_90: '0.00',
      late_90_plus: '0.00',
    },
  },
  totals: {
    purchases_count: 2,
    purchases_total: '16000.00',
    returns_count: 1,
    returns_total: '1200.00',
    payments_in: '3000.00',
    payments_out: '0.00',
    last_purchase_at: AT,
    last_payment_at: AT,
  },
  contracts: [contractSummary()],
  recent_payments: [
    {
      id: ID,
      number: 'BR1-PY-26-000001',
      direction: 'in',
      method: 'cash',
      amount: '3000.00',
      reference: null,
      received_at: AT,
      business_date: '2026-09-17',
      branch: { id: ID, name: 'Main' },
      allocated_to: [
        { kind: 'schedule_line', document_number: 'BR1-CT-26-000001 #1', amount: '3000.00' },
      ],
    },
  ],
  recent_returns: [
    {
      id: ID,
      number: 'BR1-RT-26-000001',
      kind: 'return',
      refund_method: 'contract_adjustment',
      total: '1200.00',
      sale_id: ID,
      sale_number: 'BR1-SL-26-000011',
      business_date: '2026-10-15',
      created_at: AT,
    },
  ],
  documents_count: 2,
  ...extra,
});

const statement = (extra: Record<string, unknown> = {}) => ({
  customer: { id: CUSTOMER, full_name: 'Statement Customer', status: 'active', phones: [] },
  from: '2026-10-04',
  to: '2026-10-13',
  opening_balance: '3700.00',
  closing_balance: '3400.00',
  totals: { debit: '1300.00', credit: '1600.00' },
  rows: [
    {
      date: '2026-10-06',
      kind: 'sale',
      document_id: ID,
      number: 'BR1-SL-26-000012',
      detail: null,
      reference: null,
      debit: '500.00',
      credit: '0.00',
      balance: '4200.00',
    },
    {
      date: '2026-10-06',
      kind: 'payment_in',
      document_id: ID,
      number: 'BR1-PY-26-000013',
      detail: 'bank_transfer',
      reference: 'TRX-1',
      debit: '0.00',
      credit: '500.00',
      balance: '3700.00',
    },
  ],
  ...extra,
});

describe('R02 customer account contract', () => {
  it('accepts a full account', () => {
    expect(CustomerAccount.parse(account()).balance.open_balance).toBe('15000.00');
  });

  it('accepts an empty account (no contracts, payments or returns, nulls in overdue)', () => {
    const parsed = CustomerAccount.parse(
      account({
        contracts: [],
        recent_payments: [],
        recent_returns: [],
        overdue: {
          overdue_amount: '0.00',
          overdue_lines: 0,
          max_days_late: null,
          next_due_date: null,
          next_due_amount: null,
          aging: {
            not_yet_due: '0.00',
            late_1_30: '0.00',
            late_31_60: '0.00',
            late_61_90: '0.00',
            late_90_plus: '0.00',
          },
        },
      }),
    );
    expect(parsed.contracts).toEqual([]);
  });

  it('refuses money as a number and an unknown contract status', () => {
    expect(() =>
      CustomerAccount.parse(account({ balance: { ...account().balance, open_balance: 15000 } })),
    ).toThrow();
    expect(() =>
      CustomerAccount.parse(account({ contracts: [contractSummary({ status: 'cancelled' })] })),
    ).toThrow();
  });

  it('a migrated contract has no sale', () => {
    expect(
      CustomerAccount.parse(
        account({
          contracts: [contractSummary({ sale_id: null, sale_number: null, is_migrated: true })],
        }),
      ).contracts[0]?.sale_id,
    ).toBeNull();
  });

  it('accepts a schedule with current and superseded lines and a fee', () => {
    const line = (extra: Record<string, unknown>) => ({
      id: ID,
      version: 1,
      seq: 1,
      due_date: '2026-10-11',
      principal: '2500.00',
      profit: '500.00',
      amount: '3000.00',
      paid: '0.00',
      remaining: '3000.00',
      fees_due: '0.00',
      days_late: 0,
      status: 'upcoming',
      superseded: false,
      ...extra,
    });
    const parsed = CustomerContractSchedule.parse({
      contract: contractSummary(),
      lines: [line({ version: 2 }), line({ status: 'superseded', superseded: true })],
      charges: [
        {
          id: ID,
          schedule_line_id: ID,
          seq: 2,
          kind: 'late_fee',
          assessed_on: '2026-10-13',
          amount: '150.00',
          waived: '50.00',
          paid: '0.00',
          due: '100.00',
        },
      ],
    });
    expect(parsed.lines).toHaveLength(2);
    expect(() =>
      CustomerContractSchedule.parse({
        contract: contractSummary(),
        lines: [line({ status: 'late' })],
        charges: [],
      }),
    ).toThrow();
  });

  it('the schedule params need two ids and nothing else', () => {
    expect(CustomerContractParams.parse({ id: CUSTOMER, contractId: CONTRACT })).toEqual({
      id: CUSTOMER,
      contractId: CONTRACT,
    });
    expect(() => CustomerContractParams.parse({ id: CUSTOMER })).toThrow();
    expect(() =>
      CustomerContractParams.parse({ id: CUSTOMER, contractId: CONTRACT, organization_id: ID }),
    ).toThrow();
  });

  it('accepts a statement and every row kind', () => {
    expect(CustomerStatement.parse(statement()).rows).toHaveLength(2);
    for (const kind of [
      'sale',
      'contract',
      'payment_in',
      'payment_out',
      'payment_reversal',
      'return',
      'fee',
      'fee_waiver',
    ]) {
      expect(() =>
        CustomerStatement.parse(statement({ rows: [{ ...statement().rows[0], kind }] })),
      ).not.toThrow();
    }
    expect(() =>
      CustomerStatement.parse(statement({ rows: [{ ...statement().rows[0], kind: 'refund' }] })),
    ).toThrow();
  });

  it('the statement query: optional dates, from not after to, at most three years, no other keys', () => {
    expect(CustomerStatementQuery.parse({})).toEqual({});
    expect(CustomerStatementQuery.parse({ from: '2026-01-01', to: '2026-10-16' })).toEqual({
      from: '2026-01-01',
      to: '2026-10-16',
    });
    expect(() => CustomerStatementQuery.parse({ from: '2026-10-16', to: '2026-10-15' })).toThrow();
    expect(CUSTOMER_STATEMENT_MAX_YEARS).toBe(3);
    expect(() =>
      CustomerStatementQuery.parse({ from: '2023-10-16', to: '2026-10-16' }),
    ).not.toThrow();
    expect(() => CustomerStatementQuery.parse({ from: '2023-10-15', to: '2026-10-16' })).toThrow();
    expect(() => CustomerStatementQuery.parse({ organization_id: ID })).toThrow();
    expect(() => CustomerStatementQuery.parse({ from: '16/10/2026' })).toThrow();
  });

  it('CONTRACT_NOT_FOUND is a 404', () => {
    expect(errorCodeHttpStatus.CONTRACT_NOT_FOUND).toBe(404);
  });
});
