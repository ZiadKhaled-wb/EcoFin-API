// N01: the SQL test embeds a copy of the golden cases; this keeps it equal to the fixture file
// that the TypeScript engine's tests read, so both engines always run the same cases.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const root = new URL('../../supabase/tests/', import.meta.url);

describe('N01 golden cases', () => {
  it('the SQL test embeds exactly the fixture JSON', () => {
    const fixture = JSON.parse(
      readFileSync(new URL('fixtures/n01_terms_cases.json', root), 'utf8'),
    );
    const sql = readFileSync(new URL('n01_installment_terms_test.sql', root), 'utf8');
    const embedded = /\$golden\$\s*([\s\S]*?)\s*\$golden\$/.exec(sql)?.[1];
    expect(embedded).toBeDefined();
    expect(JSON.parse(embedded!)).toEqual(fixture);
  });
});
