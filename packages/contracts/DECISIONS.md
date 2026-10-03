# Decisions (contracts repo)

Full list with reasons: `EcoFin-API/DECISIONS.md`. These are the ones that affect this package.

## Sprint 1 (3 Oct 2026)

### D1. This package is a separate repo (decided by the team)
- `@ecotech/contracts`, built with `tsc`, version `0.1.0`. Both repos use `"file:../EcoFin-Contracts"` for now.
- **Before merging Sprint 1 to `main` in the API and Web repos:** create the GitHub repo `EcoFin-Contracts`, push it, tag `v0.1.0`, and switch both repos to `"github:<owner>/EcoFin-Contracts#v0.1.0"`.
- This repo has no `main` yet. Its first commit is on `integration/sprint-1`; `main` is created when it's published.

### D5. 0.1.0 covers every Sprint 1 endpoint up front (F04 auth, F06 permissions, F07 audit search, F08 health). Later Sprint 1 builders don't change it; the master adds a missing schema if one is found.

### D21. This repo was rebuilt on 3 Oct 2026 after an accidental local wipe
`git worktree remove --force` on an API worktree followed the `node_modules/@ecotech/contracts` link on Windows and deleted this folder, `.git` included. The content was rebuilt by replaying the F03 builder's recorded steps, then checked byte-for-byte against the reviewed `npm pack` output. Commit hashes differ from the original ones; content doesn't. See `EcoFin-API/DECISIONS.md` D21 for the safe way to remove worktrees.
