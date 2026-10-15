---
name: spec-audit-and-refactor
description: >-
  Runs a Lead-Worker workflow for code audits and delegated refactoring. The Lead
  (reviewer/orchestrator) scans code read-only, writes a gap analysis, drafts a
  whitelisted spec with a Definition of Done, dispatches a Worker subagent to
  implement it inside an isolated git worktree, gates the result (scope + DoD), and
  reviews the PR diff. With several tasks it runs Workers in parallel — all at once
  when the tasks are independent, or in dependency-ordered stages (parallel within a
  stage, integrated between stages) when they are related. Use when the user asks to
  audit a codebase and fix what is found, to delegate a refactor or cleanup to one or
  more subagents in separate worktrees, to run a spec-driven or Lead-Worker
  implementation, or to review a worker's branch before merging.
---

# Spec Audit & Refactor (Lead-Worker)

`SKILL_DIR` below = the directory containing this file (e.g. `~/.agents/skills/spec-audit-and-refactor`).

## Role boundaries (non-negotiable)

| Role | May | Must not |
| :--- | :--- | :--- |
| **Lead** (you) | Read/search code, run tests/linters/builds, write specs and reviews, create/remove/integrate worktrees via `worktree.sh`; after the user's explicit yes, convert the repo to the bare-repo worktree layout with `migrate_to_bare.sh --apply`; in staged mode, once the user approved it at the checkpoint, commit approved work locally on `sar/*` branches | Edit, create, delete, or move any application file — in the main checkout **or** in a worker worktree (sole exception: `migrate_to_bare.sh --apply` as above); resolve merge conflicts by hand |
| **Worker** (subagent) | Edit files matched by its whitelist, inside its worktree, until the DoD passes | Touch non-whitelisted files, commit/push, or work outside its worktree |

If the Lead is tempted to "just fix it quickly", write it into a spec instead.

## Model assignment

Run `bash SKILL_DIR/scripts/detect_runtime.sh --agent <claude|gemini|codex>` with **your own
runtime** (you know which CLI you are running in; the flag beats env heuristics — e.g. a
Claude Code session may also have `GEMINI_API_KEY` set). Defaults:

| Ecosystem | Lead | Worker |
| :--- | :--- | :--- |
| Claude (Claude Code) | `claude-opus-5-5` · high | `claude-sonnet-5-5` · medium |
| Gemini (Antigravity) | `gemini-3.8-flash-high` · high | `gemini-3.8-flash-high` · high |
| Codex | `model` from `~/.codex/config.toml` · high | same model · medium |
| Fallback | `claude-opus-5-5` · high | `claude-sonnet-5-5` · medium |

Overrides: `SAR_LEAD_MODEL`, `SAR_LEAD_EFFORT`, `SAR_WORKER_MODEL`, `SAR_WORKER_EFFORT`.
If you are not running as the Lead model, tell the user how to switch; do not silently continue.

## Workflow

### 0. Preflight
1. `detect_runtime.sh` as above; note the `worker` block.
2. `bash SKILL_DIR/scripts/worktree.sh config` — the detected layout and its defaults
   (see [Worktree layout](#worktree-layout)); no per-repo setup is needed. Note
   `source_worktree`, `default_base`, `provision`, `max_parallel`, and `offer_bare_migration`.
   In a bare layout run every Lead git/test command inside `source_worktree` (the container
   root is not a work tree).
3. Check `bash SKILL_DIR/scripts/worktree.sh status` for leftover tasks from earlier runs.
4. If `offer_bare_migration` is `true`: run `bash SKILL_DIR/scripts/migrate_to_bare.sh`
   (dry run) and ask the user whether to convert to the **bare-repo worktree layout**, in the
   format of [references/bare-layout.md](references/bare-layout.md). Only on an explicit
   yes: `migrate_to_bare.sh --apply`, re-run `worktree.sh config`, and re-read the agent docs
   from the new `source_worktree`. Blocked or declined → continue with the standard layout.
5. Record the Lead baseline of `source_worktree`:
   `git status --porcelain=v1 && git diff HEAD | sha256sum` — keep the output.
6. If `default_base` is not `HEAD`: `git fetch` its remote, then check
   `git rev-parse HEAD` equals `git rev-parse <default_base>`. If not, the audited code
   differs from what Workers will start from — tell the user and agree on the base first.

### 1. Audit (read-only)
- Establish scope with the user (paths, concern: security / perf / debt / spec gaps).
- Scan statically; run the project's existing lint/test/type-check commands to get
  ground truth. Do not install tools or change config to do so.
- Produce a **gap report**: numbered findings, each with `file:line`, severity, evidence,
  and a proposed fix. Group findings into tasks that can each be done by one Worker with
  a small, non-overlapping whitelist.
- With more than one task, analyse dependencies and draft the **execution plan** per
  [references/execution-plan.md](references/execution-plan.md):
  - no dependencies → `independent`: one Worker per task, all in parallel;
  - related tasks → `staged`: dependency-ordered stages, parallel within each stage, each
    stage built on the integrated result of the previous one.

### 2. Spec (checkpoint)
- For each task, fill [references/worker-spec-template.md](references/worker-spec-template.md):
  slug, goal, context, whitelist, forbidden, DoD commands (and stage/dependencies).
  Fill the spec's **Repo rules** from the repo's agent docs (`AGENTS.md`, `CLAUDE.md`, and
  the ones in directories the whitelist touches): how to run tests/lint/type checks,
  required flags, language rules. Add pitfalls you know about this repo from your own
  memory that those docs do not cover, plus any `worker_notes`. Workers cannot see your
  context or memory, so anything left out is unknown to them. Write DoD commands the way
  those rules require (working directory, flags, tools).
- Save each spec and its whitelist to a scratch/temp directory (never inside a worktree).
- **Show the gap report, specs, and execution plan to the user and wait for approval**
  before step 3. In `staged` mode the approval must explicitly cover the inter-stage local
  commits and merges (no push).

Steps 3–5 run **once per stage** (`independent` mode = a single stage), in plan order.

### 3. Worktree + dispatch
1. For each task in the stage: `bash SKILL_DIR/scripts/worktree.sh path <slug>` to preview,
   then `bash SKILL_DIR/scripts/worktree.sh create <slug> [--base <ref>]` (stage 1: omit
   `--base` to use `default_base`; stage 2+: `--base sar-stage/<n-1>`). The path adapts to
   the repo (config → existing worktree layout → bare → standard); see the script header.
   Branch is `sar/<slug>`; the fork point is recorded for later diffs. Files listed under
   `provision` (gitignored secrets, venvs) are copied/linked in; check `provisioned` in the
   output and stop if an expected entry is missing.
2. Insert the worktree path and base into each spec, then dispatch **all of the stage's
   Workers in parallel** per [references/dispatch.md](references/dispatch.md) using the
   Worker model/effort (concurrency cap = `max_parallel`).

### 4. Gate (per task)
1. `bash SKILL_DIR/scripts/check_scope.sh <worktree> <whitelist-file>` — must exit 0.
   On violations: send them back to the Worker to revert (counts as a review round).
2. Re-run every DoD command yourself inside the worktree. All must exit 0.

### 5. Review (per task) + stage barrier
Follow [references/review-checklist.md](references/review-checklist.md): review the diff
against the recorded base, issue APPROVE or REQUEST_CHANGES with numbered `file:line`
findings, and loop with the Worker at most **3 rounds**, then escalate to the user.
Tasks loop independently of each other.
- `independent`: on APPROVE, ask the user before any commit, push, or `gh pr create`.
- `staged`: when every task in the stage is APPROVED, commit each locally, run
  `worktree.sh integrate <n> --base <stage base> sar/<slug>...`, and pass the integration
  gate (all of the stage's DoD in the stage worktree) before starting the next stage. See
  execution-plan.md for conflicts, integration failures, and escalated tasks.

### 6. Close-out
1. Re-run the baseline command from step 0; it must match. If it does not, report exactly
   what changed in the main checkout — do not "fix" it yourself.
2. Offer PRs (per task, or for `staged` a single PR from the last `sar-stage/<n>` or stacked
   per-stage PRs); push or `gh pr create` only with explicit consent.
3. With user consent, `bash SKILL_DIR/scripts/worktree.sh remove <slug>` for every task and
   `remove --stage <n>` for every stage (refuses dirty worktrees without `--force`; task
   branches are deleted only if merged).
4. Final summary: findings addressed, findings deferred (and their blocked dependents),
   branches/PRs created.

## Script reference
| Script | Purpose | Exit codes |
| :--- | :--- | :--- |
| `scripts/detect_runtime.sh [--agent X]` | Ecosystem + model JSON | 0 ok, 2 usage |
| `scripts/worktree.sh config\|path\|create\|integrate\|remove\|list\|status\|provision` | Layout-aware worktree lifecycle with auto-provisioning; `integrate` builds a stage's `sar-stage/<n>` branch; `status` adds state, base, ahead count and change counts per task/stage | 0 ok, 1 merge conflict (`integrate`) or dirty/missing (`status --check`), 2 error |
| `scripts/check_scope.sh <wt> <whitelist> [--base ref]` | Whitelist gate on all changes | 0 ok, 1 violations, 2 usage |
| `scripts/migrate_to_bare.sh [--apply]` | Plan (default) or perform the in-place conversion to the bare-repo worktree layout; see [references/bare-layout.md](references/bare-layout.md) | 0 ok, 1 blocked, 2 failed + rolled back, 3 rollback incomplete |
| `scripts/wt.sh add\|remove\|list\|status` | For people, not the Lead: everyday branch worktrees in the bare layout | 0 ok, 1 dirty/missing (`status --check`), 2 error |

Script tests (throwaway repos in a temp dir only): `bash SKILL_DIR/tests/migrate_bare_test.sh`,
`bash SKILL_DIR/tests/worktree_test.sh`.

## Worktree layout
Detected automatically; nothing to configure per repo. A standard repo can be converted to
the bare layout in place (preflight step 4, [references/bare-layout.md](references/bare-layout.md)).

| | Bare container (`<root>/.bare` + `<root>/main/`) | Standard repo (`.git` in the checkout) |
| :--- | :--- | :--- |
| Task worktree | `<root>/sar/<slug>` (dir = branch name) | `<parent>/worktrees/<repo>/<slug>` |
| Stage worktree | `<root>/sar-stage/<id>` | `<parent>/worktrees/<repo>/_stage-<id>` |
| Source (Lead's checkout) | worktree on the default branch, e.g. `<root>/main` | the main checkout |
| Default base | `origin/<default branch>` (else `<default branch>`) | `HEAD` |

Provisioning (both layouts): each new task/stage worktree gets the source worktree's
gitignored, untracked `.env` / `.env.*` files copied (mode kept) and `.venv` dirs symlinked,
so tests run there like in the source. Paths not gitignored in the new worktree are
skipped and never become changes. Disable with `SAR_PROVISION=0`. Workers must not edit
these files or install into a linked venv (it is the source worktree's) — the spec
template says so.

Overrides, only for a repo that deviates: env `SAR_WORKTREE_ROOT`, or
`.agents/spec-audit.json` (in `SAR_CONFIG`, the worktree toplevel, or — bare layout — the
default-branch worktree or the container root) with keys `worktreeRoot`, `pathStyle`
(`slug`|`branch`), `defaultBase`, `sourceWorktree`, `provision`
(`{"copy": [...], "link": [...], "copyMode": "644"}`, replaces auto-discovery),
`maxParallel`, `workerNotes`, `offerBareLayout` (`false` = never offer the conversion);
see `worktree.sh --help`.
Branch prefixes: `SAR_BRANCH_PREFIX` (tasks, default `sar/`), `SAR_STAGE_PREFIX` (stages, default `sar-stage/`).
