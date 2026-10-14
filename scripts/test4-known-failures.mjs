import { appendFileSync, existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
const found = [];
function visit(path) {
  if (!existsSync(path)) return;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const file = join(path, entry.name);
    if (entry.isDirectory()) visit(file);
    else if (/\.(?:sql|ts|tsx|mjs)$/.test(file))
      readFileSync(file, 'utf8')
        .split(/\r?\n/)
        .forEach((line, index) => {
          if (/BUG TEST4-B\d+:|KNOWN BUG:/.test(line))
            found.push(`${file}:${index + 1}: ${line.trim()}`);
        });
  }
}
for (const root of ['src', 'supabase/tests', 'e2e']) visit(root);
const ids = new Set(found.flatMap((line) => line.match(/TEST4-B\d+/g) ?? []));
const output = `TEST4 known failures: ${ids.size} bug IDs, ${found.length} markers\n${found.join('\n')}\n`;
console.log(output);
if (process.env.GITHUB_STEP_SUMMARY)
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `### TEST4 known failures\n\n\`\`\`text\n${output}\`\`\`\n`,
  );
