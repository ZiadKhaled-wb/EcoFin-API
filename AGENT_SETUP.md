# AGENT_SETUP.md: step 0 for every agent, every session

**Before reading your task:** go through this file. If a **mandatory** item is missing and you can't install it, **do no work.** Print the setup report (step 5) with `STATUS: BLOCKED` or `NEEDS_USER`, and stop.

---

## Step 1: Say what you are

- Agent: Claude Code / Codex CLI / Gemini CLI / Cursor / other
- Repo: `server` or `client`
- Role (from the task file): `free` or `smart`
- Task type: server, client UI, or end-to-end (E2E)

## Step 2: Check the mandatory items

Check against **your own list of available tools and files**. Don't guess, and never claim a tool you don't have.

| # | Item | Needed for | How you know you have it |
|---|---|---|---|
| M1 | Project skills `ecotech-build`, `ecotech-review` + docs | everything | Files exist: `.claude/skills/ecotech-build/SKILL.md`, `.claude/skills/ecotech-review/SKILL.md`, `docs/EcoTech_Pro_Slices.md`, `docs/EcoTech_Pro_Entities.md`, `docs/TASK_TEMPLATE.md` |
| M2 | **Context7** MCP (current library docs) | everything | You have a tool named like `resolve-library-id` |
| M3 | **security-guidance** plugin | everything, **Claude Code only** | `/plugin` lists `security-guidance`. Other agents: mark `n.a.` and run the security part of the `ecotech-review` checklist on your own diff instead. |
| M4 | **Playwright** MCP (real browser) | client UI and E2E tasks | You have tools named like `browser_navigate`, `browser_snapshot` |
| M5 | Node version | everything | `node --version` matches **v24.x** (see `.nvmrc` / `engines`) |
| M6 | Shell access | everything | You can run `typecheck`, `lint` and `test` and see the output |

## Step 3: Install what's missing

If an install needs a slash command, a config file you can't edit, or a restart: **print the exact commands for the user and stop** (`STATUS: NEEDS_USER`).

**M1 (skills, docs):** these live in the repo. If they're missing, the repo is out of date. Stop and say so; don't recreate them.

**M2 Context7:**
- Claude Code: `claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp`
- Codex CLI, in `~/.codex/config.toml`:
  ```toml
  [mcp_servers.context7]
  command = "npx"
  args = ["-y", "@upstash/context7-mcp"]
  ```
- Gemini CLI, in `~/.gemini/settings.json` under `"mcpServers"`:
  ```json
  "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
  ```
- Any other agent: add an MCP server with command `npx -y @upstash/context7-mcp`.

**M3 security-guidance (Claude Code):** the user runs `/plugin install security-guidance@claude-plugins-official`

**M4 Playwright:** same as Context7, with command `npx @playwright/mcp@latest`
- Claude Code: `claude mcp add --scope user playwright -- npx @playwright/mcp@latest`

**M5 Node:** `nvm install && nvm use` (reads `.nvmrc`). If nvm isn't available, tell the user which version is needed.

**After adding an MCP server, most agents need a restart.** Say: "Installed X. Restart this session and give me the task again." Then stop.

*Commands checked on 2 Oct 2026. If one fails, report the error and point to the tool's official README. Don't swap in a different tool.*

## Step 4: Ask about the smart tier

When every mandatory item passes, **ask once and wait:**

> "Mandatory setup is complete. Install the smart-tier tools too? Superpowers, frontend-design, React best practices, Grill Me, graphify CLI, Supabase MCP (dev only). Answer: yes / no / pick."

Install only what the user approves:

| # | Item | Install |
|---|---|---|
| S1 | **Superpowers** | Claude Code, user runs: `/plugin marketplace add obra/superpowers-marketplace`, then `/plugin install superpowers@superpowers-marketplace` |
| S2 | **frontend-design** | Claude Code, user runs: `/plugin install frontend-design@claude-plugins-official` |
| S3 | **React best practices** (Vercel) | `npx skills add vercel-labs/agent-skills` (pick your agent when asked) |
| S4 | **Grill Me** | `npx skills@latest add mattpocock/skills` (pick only `grill-me` if asked) |
| S5 | **graphify CLI** | `uv tool install graphifyy` (two y's), then `graphify --help` |
| S6 | **Supabase MCP** | Supabase's official MCP setup. **Dev/staging project only, read-only mode.** If the user can't confirm the project isn't production, don't install it. |

## Step 5: Setup report (always print this, then wait for "go")

```
SETUP REPORT
Agent: <type>   Repo: <server|client>   Role: <free|smart>   Task type: <server|client UI|E2E>
Mandatory: M1 ✅  M2 ✅  M3 ✅/n.a.  M4 ✅/n.a.  M5 ✅  M6 ✅
Smart tier: <installed list | declined | not asked>
STATUS: READY | NEEDS_USER | BLOCKED
Action for user: <exact commands, or "none">
```

Only after `STATUS: READY` **and** the user's "go" do you open the task.

---

## How to use the tools

| Tool | Use it when | Don't |
|---|---|---|
| **Context7** | Before using any library API you aren't certain of (Drizzle, Supabase, zod, React Router, Express). Ask for the version in `package.json` and the specific topic. | Code library APIs from memory, or pull whole doc sites. |
| **security-guidance** | It reviews your diff. Fix everything it flags before you return. | Silence or ignore warnings. |
| **Playwright** | Client tasks: walk the "Done when" flow in Arabic (RTL) and English. E2E release tests (Q04). | Point it at production. Use it for server-only tasks. |
| **Superpowers** | Smart agents on hard slices only (F10, S01, S05, S08, N01, N02, T02): plan, then tests first, then implement. | Use it on small CRUD tasks; it costs many tokens. |
| **frontend-design** | Designing F09 (UI shell), S06 (POS screen), D01 (dashboard). | Use it for wiring logic or forms that already have a design. |
| **React best practices** | Automatically, while writing React. | Follow it over the project rules. Project rules win. |
| **Grill Me** | Before writing the spec of a hard slice. It interviews the user about the design. | Use it in the middle of building. |
| **graphify CLI** | Smart agents: `graphify query "<q>"`, `graphify explain "<Symbol>"`, `graphify path "<A>" "<B>"` to trace code across a repo. | Rebuild or commit `graphify-out/`. Maintainers do that. |
| **Supabase MCP** | Reading the schema, logs and advisors on dev/staging. | Run writes or migrations through it. Schema changes only go through migration files. |

## The code graph (all agents)

If `graphify-out/GRAPH_REPORT.md` exists, read it **before** opening code. It names the main subsystems and central files, and it's a plain file, so no install is needed. Then open only the files your task lists, plus what they import.

- **Agents never rebuild the graph.** The maintainers run `graphify build --update` after merging a batch of tasks and commit `graphify-out/`.
- If the graph and the code disagree, **trust the code** and mention the mismatch in your summary.
