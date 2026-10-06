import { describe, it, expect } from 'vitest';
import { mapDbError } from './errors';
describe('P05 database errors', () => {
  it.each([
    ['PLAN_LIMIT_REACHED', 409],
    ['PLAN_DOWNGRADE_BLOCKED', 409],
    ['SUBSCRIPTION_EXPIRED', 403],
    ['MODULE_NOT_IN_PLAN', 403],
    ['DATES_INVALID', 400],
  ])('maps %s', (code, statusCode) =>
    expect(mapDbError({ message: code })).toMatchObject({ code, statusCode }),
  );
  it('only passes validated resource details', () => {
    const details = { resource: 'branches', limit: 1, used: 1 };
    expect(
      mapDbError({ message: 'PLAN_LIMIT_REACHED', details: JSON.stringify(details) }),
    ).toMatchObject({ details });
    expect(
      mapDbError({ message: 'PLAN_DOWNGRADE_BLOCKED', details: JSON.stringify([details]) }),
    ).toMatchObject({ details: [details] });
    for (const raw of ['broken', '{"token":"secret"}', '{"resource":"other","used":1,"limit":1}'])
      expect(mapDbError({ message: 'PLAN_LIMIT_REACHED', details: raw })?.details).toBeUndefined();
    expect(
      mapDbError({ message: 'SUBSCRIPTION_EXPIRED', details: '{"token":"secret"}' })?.details,
    ).toBeUndefined();
  });
});
