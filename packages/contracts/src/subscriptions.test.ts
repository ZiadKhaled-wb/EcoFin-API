import { describe, it, expect } from 'vitest';
import {
  SubscriptionPaymentBody,
  SubscriptionDatesBody,
  SubscriptionUsage,
  SUBSCRIPTION_WARNING_DAYS,
} from './subscriptions.js';
describe('P05 subscription contracts', () => {
  it.each(['0', '-1', '1e3', 10])('refuses non-positive or non-decimal amount %s', (amount) =>
    expect(
      SubscriptionPaymentBody.safeParse({
        amount,
        period_start: '2026-10-01',
        period_end: '2026-10-31',
      }).success,
    ).toBe(false),
  );
  it('accepts decimal string and defaults extend', () =>
    expect(
      SubscriptionPaymentBody.parse({
        amount: '500.25',
        period_start: '2026-10-01',
        period_end: '2026-10-31',
      }).extend,
    ).toBe(true));
  it('validates real dates and order', () => {
    expect(
      SubscriptionDatesBody.safeParse({ start: '2026-02-30', end: null, reason: 'renew' }).success,
    ).toBe(false);
    expect(
      SubscriptionDatesBody.safeParse({ start: '2026-10-02', end: '2026-10-01', reason: 'renew' })
        .success,
    ).toBe(false);
    expect(
      SubscriptionDatesBody.parse({ start: '2026-10-01', end: null, reason: 'renew' }).end,
    ).toBeNull();
  });
  it('unlimited counts and warning', () => {
    expect(SUBSCRIPTION_WARNING_DAYS).toBe(14);
    expect(
      SubscriptionUsage.parse({
        branches: { used: 10, limit: null },
        users: { used: 4, limit: 5 },
        devices: { used: 0, limit: 2 },
        modules: ['pos'],
      }).branches.limit,
    ).toBeNull();
  });
});
