// D39: a migration added by a branch must be numbered AFTER every migration already on the base
// (origin/main for a pull request, the previous commit for a push to main). Supabase's
// `db push` refuses an older-numbered migration once a newer one is applied on the hosted
// database, which is what blocked the dev deploy of PR 25 (6 Oct). CI builds from zero in file
// order, so without this check it can't see the problem.
// Usage: node scripts/check-migration-order.mjs <base ref or sha>
import { execFileSync } from 'node:child_process';

const DIR = 'supabase/migrations';
const base = process.argv[2];

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const versionOf = (name) => /^(\d{14})_/.exec(name)?.[1];
const list = (ref) =>
  git('ls-tree', '--name-only', `${ref}:${DIR}`)
    .split('\n')
    .filter((n) => n.endsWith('.sql'));

const head = list('HEAD');
const problems = [];

// Every file is <14-digit version>_<name>.sql and no version is used twice.
const seen = new Map();
for (const name of head) {
  const v = versionOf(name);
  if (!v) problems.push(`${name}: the name must start with a 14-digit version and _`);
  else if (seen.has(v)) problems.push(`${name}: version ${v} is also used by ${seen.get(v)}`);
  else seen.set(v, name);
}

if (base && !/^0+$/.test(base)) {
  const before = list(base);
  const newest = before.map(versionOf).filter(Boolean).sort().at(-1) ?? '';
  const added = head.filter((n) => !before.includes(n));
  for (const name of added) {
    const v = versionOf(name);
    if (v && v <= newest) {
      problems.push(
        `${name}: numbered before ${newest}, the newest migration already on ${base}. ` +
          `Renumber it after ${newest} (hosted databases refuse older-numbered migrations).`,
      );
    }
  }
  console.log(
    `migration order: ${added.length} new since ${base} (newest there: ${newest || 'none'})`,
  );
}

if (problems.length > 0) {
  for (const p of problems) console.error(`MIGRATION ORDER: ${p}`);
  process.exit(1);
}
console.log(`migration order: ${head.length} migrations, all named and ordered correctly`);
