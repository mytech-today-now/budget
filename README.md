# Budget Rule SKILL — Token & Edit Discipline for AI Coding Agents

A drop-in operating rule that forces any agentic coding assistant — **Claude Code**,
**OpenAI Codex / ChatGPT**, **Cursor**, **Cline**, **Roo Code**, **Windsurf**,
**GitHub Copilot**, **Augment Code**, **Aider**, and any other system-prompt-driven
agent — to deliver **exactly what was asked, nothing more**, at the lowest
defensible token and diff cost.

The rule itself lives in one file: **[`.agents/budget-rule-SKILL.md`](.agents/budget-rule-SKILL.md)**.
Everything else in this repo is auxiliary.

---

## What the rule enforces

- **Minimum viable change set** — smallest coherent diff that satisfies the request.
- **Scope lock** — no "while I'm in there" refactors, renames, or reformatting.
- **Output economy** — terse, action-oriented responses by default; no preambles,
  recaps, or unsolicited summaries.
- **No unsolicited files** — especially no new `README*`, `*.md`, changelogs,
  or "summary" files unless explicitly requested.
- **Decision escalation** — when ambiguous, destructive, or out-of-scope, the
  agent stops and asks a single focused question with 2–4 options instead of
  guessing silently.
- **Opt-in verbose mode** — full explanation only when you ask for it
  (`"be verbose"`, `"walk me through"`, `"explain the tradeoffs"`).

Read the full rule: **[`.agents/budget-rule-SKILL.md`](.agents/budget-rule-SKILL.md)**.

---

## Installation

The rule is plain prompt text. Install it by placing the contents of
`.agents/budget-rule-SKILL.md` wherever your AI tool reads project or system
instructions from. Pick the section for your tool:

### Claude Code (Anthropic)

Append the rule to your project's `CLAUDE.md` (or `~/.claude/CLAUDE.md` for
global use across all projects):

```bash
cat .agents/budget-rule-SKILL.md >> CLAUDE.md
```

Claude Code loads `CLAUDE.md` automatically on every session.

### OpenAI Codex CLI / `codex` agent

Place the rule in `AGENTS.md` at the repo root, or in `~/.codex/AGENTS.md`
for global use:

```bash
cp .agents/budget-rule-SKILL.md AGENTS.md
```

### OpenAI ChatGPT — Custom GPT / Projects / Custom Instructions

Open your Custom GPT (or Project, or account-level Custom Instructions),
paste the entire contents of `.agents/budget-rule-SKILL.md` into the
**System / Instructions** field, and save.

### Cursor

Save the rule as `.cursorrules` at the project root, **or** as
`.cursor/rules/budget-rule.mdc` for the newer rules format:

```bash
cp .agents/budget-rule-SKILL.md .cursorrules
```

### Cline / Roo Code (VS Code extensions)

Either:
- Save the rule as `.clinerules` (Cline) or `.roo/rules/budget-rule.md` (Roo)
  at the project root, **or**
- Paste the rule into the extension's **Custom Instructions** setting
  (Settings → Cline/Roo → Custom Instructions).

### GitHub Copilot (Chat / Workspace)

Save the rule at `.github/copilot-instructions.md`:

```bash
mkdir -p .github && cp .agents/budget-rule-SKILL.md .github/copilot-instructions.md
```

Copilot Chat reads this file automatically for repo-aware conversations.

### Windsurf (Codeium)

Save as `.windsurfrules` at the project root, **or** as
`.windsurf/rules/budget-rule.md` for the newer rules format.

### Augment Code

Save into `.augment/rules/budget-rule.md` — Augment auto-loads any
`.md` file under `.augment/rules/`.

### Aider

Append the rule to `.aider.conf.yml` under `read:` as a referenced file,
or pass it on the command line:

```bash
aider --read .agents/budget-rule-SKILL.md
```

### Any other agent / generic system prompt

Prepend the contents of `.agents/budget-rule-SKILL.md` to your system prompt.
The rule is written as a tool-agnostic behavioral contract — it does not
depend on any specific runtime, model, or tool harness.

---

## Usage

Once installed, the rule is **active by default**: quiet, surgical, scope-locked.

### Asking for verbose output

The rule's verbose mode is opt-in **per turn**. Trigger it explicitly:

> "Be verbose — explain the design tradeoffs."
> "Walk me through this implementation."
> "Comprehensive review, please."

The agent reverts to quiet mode on the next turn automatically.

### Verifying the rule is loaded

A correctly-loaded agent will:
- Stop and ask before adding new files, dependencies, or refactors.
- Respond with one-line confirmations instead of multi-paragraph status reports.
- Flag — not silently fix — out-of-scope issues it notices.

If your agent still produces unsolicited refactors, summary files, or
multi-paragraph recaps, the rule is not being read — re-check the install
step for your tool.

---

## Repo layout

```
.agents/budget-rule-SKILL.md   The SKILL (the star of this repo)
ai-prompts/                    Auxiliary prompt material
scripts/                       Auxiliary PowerShell tooling — see scripts/README.md
```
