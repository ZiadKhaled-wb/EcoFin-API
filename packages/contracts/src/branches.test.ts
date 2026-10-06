import { describe, it, expect } from 'vitest';
import {
  BranchCreateBody,
  BranchUpdateBody,
  BranchDeactivateBody,
  BranchDeactivationCheck,
} from './branches';
describe('O01 branch contracts', () => {
  it('normalizes code and name and rejects invalid codes', () => {
    expect(BranchCreateBody.parse({ name: ' Second ', code: 'b2' })).toMatchObject({
      name: 'Second',
      code: 'B2',
    });
    for (const code of ['', 'TOOLONG7', 'A-B', 'A B'])
      expect(BranchCreateBody.safeParse({ name: 'B', code }).success).toBe(false);
  });
  it('requires name, limits ETA code, and forbids changing code on update', () => {
    expect(BranchCreateBody.safeParse({ name: ' ', code: 'B2' }).success).toBe(false);
    expect(
      BranchCreateBody.safeParse({ name: 'B', code: 'B2', eta_branch_code: 'x'.repeat(21) })
        .success,
    ).toBe(false);
    expect(BranchUpdateBody.safeParse({ name: 'B', code: 'B2' }).success).toBe(false);
  });
  it('requires a deactivation reason and preserves decimal cash details', () => {
    expect(BranchDeactivateBody.safeParse({ reason: ' ' }).success).toBe(false);
    expect(BranchDeactivateBody.parse({ reason: 'close' }).confirm).toBe(false);
    expect(
      BranchDeactivationCheck.parse({ open_shifts: 1, stock_units: 2, cash_balance: '30.25' })
        .cash_balance,
    ).toBe('30.25');
    expect(
      BranchDeactivationCheck.safeParse({ open_shifts: 1, stock_units: 2, cash_balance: 30.25 })
        .success,
    ).toBe(false);
  });
});
