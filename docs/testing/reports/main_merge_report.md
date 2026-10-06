# Merge latest main into feat/shop

Date: 2026-10-06
Status: done

## Sources

- API main: 20efad3 (EC-142 file registration tenant check; EC-143 employee activation).
- Web main: 1d0bb9a (account-menu shop switching and current-shop badge).
- Existing P01, P05, O01 and O02 commits retained. No history rewrite or push.

## Resolutions

- Combined contract additions in version 0.8.1 and regenerated the Web vendor package/lockfile.
- One activation route returns both response naming conventions. One employee.active_set warning audit per actual state change; no audit for unchanged state.
- Preserved O02 token locking/revocation, subscription limit triggers, and optional reactivation reason. Deactivation still requires a reason. Owner/self and foreign targets use EC-143 FORBIDDEN/NOT_FOUND errors.
- Two new compatibility migrations reconcile the duplicate RPC signature and behavior. Both existing migrations stay unchanged. Fresh reset succeeds.
- Kept all shop-task UI behavior alongside upstream shop switching and current-shop indication.
- EC-142's direct-RPC security regression now passes as a normal test; no expected failure remains.
- CLAUDE.md was not edited or committed; the preexisting API working-tree edit is preserved.

## Verification

- API typecheck and lint passed.
- API complete local integration/unit suite: 665 passed, 55 files, sequential file execution.
- Shared contracts: 126 passed.
- All 17 SQL suites: 664 passed, zero failures.
- Web typecheck and lint passed (existing DataTable compiler warning).
- Web unit suite: 188 passed, 30 files.
- Real Chrome checks passed in English/LTR and Arabic/RTL: multi-shop login, account menu switch, current badge, switch to the other shop. Screenshots inspected.
- Security diff checked: tenant and permission enforcement, private token revocation, explicit RPC grants, empty search_path, one transactional audit.

No outstanding decision or blocker. Local test services stopped after verification.
