// Writes src/types/database.types.ts from `supabase gen types typescript --local` output.
// Usage (see package.json "db:types"): <supabase gen types ...> | node scripts/db-types.mjs
// Adds a "generated" header and formats with the repo's Prettier config, so a regenerate
// right after `npm run db:reset` gives no diff and `npm run format:check` passes.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as prettier from 'prettier';

const target = fileURLToPath(new URL('../src/types/database.types.ts', import.meta.url));

const HEADER = `// GENERATED FILE - DO NOT EDIT BY HAND.
// Source: local database (supabase/migrations), schema "public".
// Regenerate after a migration change: npm run db:reset && npm run db:types
`;

let generated = readFileSync(0, 'utf8');
if (!generated.includes('export type Database')) {
  console.error('db:types: no generated types on stdin (is the local stack running?)');
  process.exit(1);
}

// PostgreSQL does not expose function-argument nullability. F14 accepts NULL for
// these parameters; preserve that existing contract whenever CLI types regenerate.
generated = generated.replace(/"?register_file"?:\s*\{[\s\S]*?Returns:/, (signature) =>
  signature.replace(
    /("?p_(?:entity_id|entity_type|original_name|sha256)"?:\s*string)(?! \| null)/g,
    '$1 | null',
  ),
);
const config = (await prettier.resolveConfig(target)) ?? {};
// O01 nullable address/vault/reason RPC arguments are not inferred by PostgreSQL.
generated = generated.replace(
  /"?(?:create_branch|update_branch|set_branch_active)"?:\s*\{[\s\S]*?Returns:/g,
  (signature) =>
    signature.replace(
      /("?p_(?:address|city|governorate|phone|eta_branch_code|default_cash_account_id|reason)"?:\s*string)(?! \| null)/g,
      '$1 | null',
    ),
);
generated = generated.replace(
  /"?admin_set_subscription_dates"?:\s*\{[\s\S]*?Returns:/,
  (signature) => signature.replace(/("?p_end"?:\s*string)(?! \| null)/g, '$1 | null'),
);
generated = generated.replace(
  /"?admin_record_subscription_payment"?:\s*\{[\s\S]*?Returns:/,
  (signature) => signature.replace(/("?p_reference"?:\s*string)(?! \| null)/g, '$1 | null'),
);
// numeric accepts a decimal string over PostgREST; billing never uses JS float money.
generated = generated.replace(
  /"?admin_record_subscription_payment"?:\s*\{[\s\S]*?Returns:/,
  (signature) => signature.replace(/("?p_amount"?:\s*)number/g, '$1string'),
);
// O02: PostgreSQL does not expose nullable input parameters. JSON response nulls are schema-validated.
generated = generated.replace(
  /"?(?:create_employee|update_employee|set_employee_active|list_employees)"?:\s*\{[\s\S]*?Returns:/g,
  (signature) =>
    signature.replace(
      /("?p_(?:phone|email|username|default_branch_id|reason|search|status)"?:\s*string)(?! \| null)/g,
      '$1 | null',
    ),
);
generated = generated.replace(/"?list_employees"?:\s*\{[\s\S]*?Returns:/, (signature) =>
  signature.replace(/("?p_role"?:\s*Database[^,;\n}]+)/, '$1 | null'),
);
// I02: a count without a category covers the whole branch; an adjustment note is optional.
generated = generated.replace(/"?create_stock_count"?:\s*\{[\s\S]*?Returns:/, (signature) =>
  signature.replace(/("?p_category_id"?:\s*string)(?! \| null)/g, '$1 | null'),
);
generated = generated.replace(/"?post_stock_adjustment"?:\s*\{[\s\S]*?Returns:/, (signature) =>
  signature.replace(/("?p_note"?:\s*string)(?! \| null)/g, '$1 | null'),
);
// I03: transfer notes are optional.
generated = generated.replace(
  /"?(?:create_stock_transfer|update_stock_transfer)"?:\s*\{[\s\S]*?Returns:/g,
  (signature) => signature.replace(/("?p_notes"?:\s*string)(?! \| null)/g, '$1 | null'),
);
const formatted = await prettier.format(`${HEADER}\n${generated}`, { ...config, filepath: target });
writeFileSync(target, formatted);
console.log(`db:types: wrote ${target}`);
