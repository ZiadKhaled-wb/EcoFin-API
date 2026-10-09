import { describe, it, expect } from 'vitest';
import {
  CashAccount,
  CashAccountCreateBody,
  CashAccountList,
  CashAccountListQuery,
  CashAccountUpdateBody,
  CashLedger,
  CashLedgerQuery,
  CashOpeningBody,
  CashTransfer,
  CashTransferCreateBody,
  CashTransferList,
  CashTransferListQuery,
} from './cash.js';
import { errorCodeHttpStatus } from './errors.js';

const safe = 'a0590000-0000-4000-8000-000000000001';
const bank = 'a0590000-0000-4000-8000-000000000002';
const branch = 'a0590000-0000-4000-8000-000000000003';
const account = {
  id: safe,
  name: 'Main safe',
  kind: 'safe',
  branch_id: branch,
  branch_name: 'Main',
  is_active: true,
  archived_at: null,
  balance: '3800.00',
  is_default: true,
  created_at: '2026-10-11T08:00:00.000Z',
  updated_at: '2026-10-11T08:00:00.000Z',
};
const transfer = {
  id: 'a0590000-0000-4000-8000-000000000004',
  number: 'MAIN-CX-26-000001',
  from_account_id: safe,
  from_account_name: 'Main safe',
  to_account_id: bank,
  to_account_name: 'NBE',
  amount: '1200.00',
  note: null,
  business_date: '2026-10-11',
  created_by_name: 'Owner',
  created_at: '2026-10-11T08:00:00.000Z',
};

describe('cash contracts (K01)', () => {
  it('parses accounts, a shop-wide bank and the list', () => {
    expect(CashAccount.parse(account)).toEqual(account);
    const shopWide = {
      ...account,
      id: bank,
      kind: 'bank',
      branch_id: null,
      branch_name: null,
      is_default: false,
    };
    expect(CashAccountList.parse([account, shopWide])).toHaveLength(2);
    expect(CashAccount.safeParse({ ...account, kind: 'drawer' }).success).toBe(false);
  });

  it('list query: active by default, strict', () => {
    expect(CashAccountListQuery.parse({})).toEqual({ status: 'active' });
    expect(CashAccountListQuery.safeParse({ status: 'archived' }).success).toBe(false);
    expect(CashAccountListQuery.safeParse({ organization_id: branch }).success).toBe(false);
  });

  it('create: trims the name; a safe needs a branch, a bank may be shop-wide', () => {
    expect(
      CashAccountCreateBody.parse({ name: '  Back safe ', kind: 'safe', branch_id: branch }).name,
    ).toBe('Back safe');
    expect(
      CashAccountCreateBody.safeParse({ name: 'Loose', kind: 'safe', branch_id: null }).success,
    ).toBe(false);
    expect(
      CashAccountCreateBody.safeParse({ name: 'NBE', kind: 'bank', branch_id: null }).success,
    ).toBe(true);
    expect(
      CashAccountCreateBody.safeParse({ name: ' ', kind: 'bank', branch_id: null }).success,
    ).toBe(false);
    expect(
      CashAccountCreateBody.safeParse({ name: 'n'.repeat(101), kind: 'bank', branch_id: null })
        .success,
    ).toBe(false);
    expect(
      CashAccountCreateBody.safeParse({ name: 'D', kind: 'drawer', branch_id: branch }).success,
    ).toBe(false);
    expect(CashAccountUpdateBody.safeParse({ name: 'X', kind: 'bank' }).success).toBe(false);
  });

  it('opening: amount above 0 with 2 decimals at most, a note of 3-500', () => {
    expect(CashOpeningBody.parse({ amount: '5000.00', note: ' Day one ' }).note).toBe('Day one');
    for (const amount of ['0', '0.00', '-1.00', '1.005', '1e3']) {
      expect(CashOpeningBody.safeParse({ amount, note: 'Day one' }).success).toBe(false);
    }
    expect(CashOpeningBody.safeParse({ amount: '1.00', note: 'ab' }).success).toBe(false);
  });

  it('transfer: two different accounts, amount above 0, optional note', () => {
    const body = { from_account_id: safe, to_account_id: bank, amount: '1200.00', note: '  ' };
    expect(CashTransferCreateBody.parse(body).note).toBeUndefined();
    expect(CashTransferCreateBody.safeParse({ ...body, to_account_id: safe }).success).toBe(false);
    expect(CashTransferCreateBody.safeParse({ ...body, amount: '0.00' }).success).toBe(false);
    expect(CashTransferCreateBody.safeParse({ ...body, note: 'n'.repeat(501) }).success).toBe(
      false,
    );
    expect(CashTransfer.parse(transfer)).toEqual(transfer);
    expect(
      CashTransferList.parse({ items: [transfer], page: 1, pageSize: 50, total: 1 }).total,
    ).toBe(1);
  });

  it('dates: from must not be after to', () => {
    expect(CashTransferListQuery.safeParse({ from: '2026-10-12', to: '2026-10-11' }).success).toBe(
      false,
    );
    expect(CashLedgerQuery.safeParse({ from: '2026-10-12', to: '2026-10-11' }).success).toBe(false);
    expect(CashLedgerQuery.parse({ from: '2026-10-01' }).from).toBe('2026-10-01');
  });

  it('ledger: signed amounts and running balances', () => {
    const ledger = {
      account,
      from: null,
      to: null,
      opening_balance: '0.00',
      closing_balance: '3800.00',
      items: [
        {
          id: 'a0590000-0000-4000-8000-000000000005',
          business_date: '2026-10-11',
          created_at: '2026-10-11T08:00:00.000Z',
          type: 'transfer_out',
          amount: '-1200.00',
          balance_after: '3800.00',
          source_type: 'cash_transfer',
          source_id: transfer.id,
          source_number: transfer.number,
          note: null,
          created_by_name: 'Owner',
        },
      ],
      page: 1,
      pageSize: 50,
      total: 1,
    };
    expect(CashLedger.parse(ledger).items[0]?.amount).toBe('-1200.00');
  });

  it('error codes', () => {
    expect(errorCodeHttpStatus.CASH_ACCOUNT_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.CASH_TRANSFER_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.CASH_ACCOUNT_NAME_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.CASH_ACCOUNT_HAS_BALANCE).toBe(409);
    expect(errorCodeHttpStatus.CASH_ACCOUNT_IS_DEFAULT).toBe(409);
    expect(errorCodeHttpStatus.CASH_ACCOUNT_INACTIVE).toBe(409);
    expect(errorCodeHttpStatus.CASH_ACCOUNT_HAS_MOVEMENTS).toBe(409);
    expect(errorCodeHttpStatus.TRANSFER_SAME_ACCOUNT).toBe(400);
  });
});
