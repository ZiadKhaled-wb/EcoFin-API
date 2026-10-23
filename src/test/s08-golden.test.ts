// S08 (S1, U2): the SQL test embeds a copy of the offline totals fixture; this keeps it equal to the
// fixture file the contracts' computeOfflineTotals test reads, so both engines run the same cases.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const root = new URL('../../supabase/tests/', import.meta.url);

describe('S08 offline totals cases', () => {
  it('the SQL test embeds exactly the fixture JSON', () => {
    const fixture = JSON.parse(
      readFileSync(new URL('fixtures/s08_offline_totals.json', root), 'utf8'),
    );
    const sql = readFileSync(new URL('s08_offline_test.sql', root), 'utf8');
    const embedded = /\$golden\$\s*([\s\S]*?)\s*\$golden\$/.exec(sql)?.[1];
    expect(embedded).toBeDefined();
    expect(JSON.parse(embedded!)).toEqual(fixture);
  });
});
