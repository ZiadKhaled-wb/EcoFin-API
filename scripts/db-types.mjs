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

const generated = readFileSync(0, 'utf8');
if (!generated.includes('export type Database')) {
  console.error('db:types: no generated types on stdin (is the local stack running?)');
  process.exit(1);
}

const config = (await prettier.resolveConfig(target)) ?? {};
const formatted = await prettier.format(`${HEADER}\n${generated}`, { ...config, filepath: target });
writeFileSync(target, formatted);
console.log(`db:types: wrote ${target}`);
