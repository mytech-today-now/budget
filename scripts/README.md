# scripts/ — Auxiliary Tooling

PowerShell helpers that support workflows in this repo. **These scripts are
secondary.** The star of this repo is the Budget Rule SKILL at
**[`../.agents/budget-rule-SKILL.md`](../.agents/budget-rule-SKILL.md)** —
see the [root README](../README.md) for how to load it into Claude Code,
OpenAI Codex / ChatGPT, Cursor, Cline, Copilot, Windsurf, Augment, Aider,
or any other AI coding agent.

> **Recommended workflow:** Before letting an AI agent run, edit, or extend
> any script in this folder, ensure the agent has the budget-rule SKILL
> loaded. The SKILL prevents the agent from "improving" scripts unilaterally,
> adding speculative helpers, or creating unsolicited companion files.

---

## Beads issue tracker (primary script suite)

The bulk of the scripts here implement **Beads** — a lightweight, git-backed,
append-only task store kept in `.beads/issues.jsonl`. Beads is used as the
task queue that the agent (operating under the budget-rule SKILL) reads
from and writes to.

---

## Files

| File | Purpose |
|------|---------|
| `beads-query.ps1` | Core CLI engine. All commands are implemented here. |
| `beads-helpers.ps1` | Dot-source this to get the `bd` alias and typed wrapper functions. |

---

## Quick Start

Always run from the **repository root** (where `.beads/` lives):

```powershell
# Load the bd alias + all helper functions (required before any bd command)
. .\scripts\beads-helpers.ps1

# Verify it loaded
bd-help
```

> **Important:** The dot-source (`. .\scripts\beads-helpers.ps1`) must be re-run
> in every new PowerShell session. Add it to your profile or session setup script
> to persist across sessions.

---

## Data Store

| Item | Value |
|------|-------|
| File | `.beads/issues.jsonl` |
| Format | Append-only JSONL; last record for each `id` wins (delta/patch model) |
| ID format | `bd-xxxx` (4 random base-36 characters, e.g. `bd-a3f9`) |
| Statuses | `open` · `in-progress` · `closed` |
| Priorities | `1` (highest) · `2` · `3` (default/lowest) |
| Types | `task` (default) · any string |

---

## `bd` Command Reference

After dot-sourcing `beads-helpers.ps1`, use `bd` exactly like a CLI tool.

### list
```powershell
bd list                          # all issues, sorted by priority
bd list --status open            # filter by status: open | in-progress | closed
bd list --limit 10               # cap results
bd list --json                   # compact JSON array output
```

### show
```powershell
bd show <id>                     # human-readable detail view
bd show <id> --json              # full JSON object
```

### ready
```powershell
bd ready                         # top-5 + bottom-5 unblocked open issues
bd ready --limit 10              # top N unblocked first, then blocked
bd ready --json                  # JSON: { top, tail, total }
```

### search
```powershell
bd search "keyword"              # substring match on title + description
bd search "keyword" --json
```

### create
```powershell
bd create "Task title"
bd create "Task title" -Description "Details here" -Priority 1 -Type task
```
- `-Priority`: `1`=high, `2`=medium, `3`=low (default: `3`)
- `-Type`: any string, default `task`

### update
```powershell
bd update <id> --claim           # set status=in-progress, claimed_by=$env:USERNAME
bd update <id> --status open
bd update <id> --status in-progress
bd update <id> -Priority 1
bd update <id> --json            # return updated JSON object
```

### close
```powershell
bd close <id>                    # close with no reason
bd close <id> --reason "done"    # close with a reason string
bd close <id> --json
```

### dep (dependencies)
```powershell
bd dep add    <id> <dep-id>      # id is BLOCKED BY dep-id (default type: blocks)
bd dep list   <id>               # list all dependencies for id
bd dep remove <id> <dep-id>      # remove the dependency
bd dep add    <id> <dep-id> -DepType "relates-to"   # custom relationship type
```

### stats
```powershell
bd stats                         # summary by status and priority
bd stats --json
```

---

## Typed Wrapper Functions

These are strongly-typed PowerShell functions that call `bd` internally.
Prefer them when scripting or calling from other `.ps1` files.

```powershell
bd-list-open                                        # bd list --status open
bd-list-all                                         # bd list
bd-show        -Id <id>                             # bd show <id>
bd-ready                                            # bd ready
bd-create      -Title "…" [-Description "…"] [-Priority 1] [-Type task]
bd-update      -Id <id>   [-Status open|in-progress] [-Claim] [-Priority 1]
bd-close       -Id <id>   [-Reason "done"]
bd-search      -Query "keyword"
bd-dep         add|list|remove <id> [dep-id]
bd-list-augext                                      # search for "augext" issues
bd-list-charcount                                   # search for "charcount" issues
bd-help                                             # print this function list
```

---

## Common Patterns for AI Agents

### Check what needs to be done next
```powershell
bd ready           # highest-priority unblocked tasks first
bd list --status open
```

### Claim a task before starting work
```powershell
bd update <id> --claim     # marks in-progress, sets claimed_by to your username
```

### Complete a task
```powershell
bd close <id> --reason "Implemented in …"
```

### Dependency chain example
```powershell
# bd-a1b2 is blocked by bd-c3d4 (must finish c3d4 first)
bd dep add bd-a1b2 bd-c3d4
bd dep list bd-a1b2
bd dep remove bd-a1b2 bd-c3d4   # once dependency is resolved
```

---

## Smoke Test

Run the full lifecycle smoke test to verify the scripts are working correctly.
The test backs up and restores real data automatically.

```powershell
pwsh -File .\scripts\_smoke-test.ps1
```

---

## Bulk Task Creation Pattern

Use the `_bulk-create-tasks.ps1` pattern as a template:

```powershell
. .\scripts\beads-helpers.ps1

$tasks = @(
    @{ title="[prefix] Task one";   desc="Details"; pri=1; type="task" },
    @{ title="[prefix] Task two";   desc="Details"; pri=2; type="task" }
)

foreach ($t in $tasks) {
    bd create $t.title -Description $t.desc -Priority $t.pri -Type $t.type
}

bd stats
```

