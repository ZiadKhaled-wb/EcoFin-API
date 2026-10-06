// D39: a migration added by a branch must be numbered AFTER every migration already on the base
// (origin/main for a pull request, the previous commit for a push to main). Supabase's
// `db push` refuses an older-numbered migration once a newer one is applied on the hosted
// database, which is what blocked the dev deploy of PR 25 (6 Oct). CI builds from zero in file
// order, so without this check it can't see the problem.
// Usage: node scripts/check-migration-order.mjs <base ref or sha> [ref to check, default HEAD]
import { execFileSync } from 'node:child_process';

const DIR = 'supabase/migrations';
const base = process.argv[2];
const target = process.argv[3] ?? 'HEAD';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const versionOf = (name) => /^(\d{14})_/.exec(name)?.[1];
const list = (ref) =>
  git('ls-tree', '--name-only', `${ref}:${DIR}`)
    .split('\n')
    .filter((n) => n.endsWith('.sql'));

const head = list(target);
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
  // Added files must come after the newest migration on the base. A rename (git's R status) is a
  // deliberate renumbering of migrations that were never applied to a hosted database (D39): it
  // is listed, not refused. Never rename a migration that a hosted database already has.
  const changes = git('diff', '--name-status', '-M', base, target, '--', DIR)
    .split('\n')
    .filter(Boolean)
    .map((line) => line.split('\t'));
  const fileName = (path) => path.split('/').at(-1);
  const renamed = changes.filter(([status]) => status.startsWith('R'));
  // A deleted file and an added one with the same name after the version: also a renumbering
  // (git only reports R when the content stayed mostly the same).
  const suffix = (name) => name.replace(/^\d{14}_/, '');
  const deleted = changes.filter(([status]) => status === 'D').map(([, path]) => fileName(path));
  const added = [];
  for (const [status, path] of changes) {
    if (status !== 'A') continue;
    const name = fileName(path);
    const twin = deleted.find((d) => suffix(d) === suffix(name));
    if (twin) renamed.push(['R', twin, name]);
    else added.push(name);
  }
  for (const name of added) {
    const v = versionOf(name);
    if (v && v <= newest) {
      problems.push(
        `${name}: numbered before ${newest}, the newest migration already on ${base}. ` +
          `Renumber it after ${newest} (hosted databases refuse older-numbered migrations).`,
      );
    }
  }
  for (const [, from, to] of renamed) {
    console.log(
      `migration order: renumbered ${fileName(from)} -> ${fileName(to)} ` +
        '(only safe if it was never applied to a hosted database)',
    );
  }
  console.log(
    `migration order: ${added.length} new, ${renamed.length} renumbered since ${base} ` +
      `(newest there: ${newest || 'none'})`,
  );
}

if (problems.length > 0) {
  for (const p of problems) console.error(`MIGRATION ORDER: ${p}`);
  process.exit(1);
}
console.log(`migration order: ${head.length} migrations, all named and ordered correctly`);
