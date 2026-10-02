# Task template

*Copy this for every task you hand to an agent. One task = one agent run. A slice usually becomes 1–3 tasks (contract + server, client, tests). Fill every field: an empty field is where free agents go wrong.*

```markdown
# Task <ID>: <short title>

**Slice:** <e.g. U01 · Suppliers>   **Repo:** server | client   **Agent:** smart | free
**Skill:** use `ecotech-build`

## Goal
<One or two sentences: what the user can do after this task.>

## Files you may touch
- <path>  (create | edit)
- <path>
Anything else: don't edit; mention it in your summary.

## Contract (from the shared contracts package)
- Endpoint: <METHOD /path>
- Request schema: <SchemaName>
- Response schema: <SchemaName>
- Error codes: <CODE_1, CODE_2>
- Permission: <permission.key>

## Behaviour
1. <exact rule>
2. <exact rule>
3. <edge case and what to do>

## Old code to port (if any)
- <old path>: keep <what>, change <what>

## Done when
- [ ] <check copied from the slice + task-specific checks>
- [ ] Cross-tenant test for every endpoint
- [ ] typecheck, lint, test pass

## Out of scope
- <things the agent must not do in this task>
```
