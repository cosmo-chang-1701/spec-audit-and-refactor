# Execution Plan (multiple Workers)

When the audit yields more than one task, the Lead decides how Workers run before the
spec checkpoint: **independent** (all in parallel at once) or **staged** (parallel within a
stage, stages in order). The plan is shown to the user in the checkpoint report (§3).

## 1. Dependency analysis
Task B **depends on** task A when any of these hold:
- B uses a symbol, API, schema, config key, or behaviour that A adds or changes.
- B's DoD can only pass once A's change exists.
- B's whitelist overlaps A's — including shared hot spots such as route/registry/index
  files, lockfiles, migrations, or a common test fixture. Overlapping tasks never share a stage.
  `check_scope.sh --overlap <source_worktree> <a>.wl <b>.wl ...` lists shared tracked files
  (`OVERLAP`) and patterns that could meet on a new file (`POSSIBLE`).

Cycles mean the split is wrong: merge the tasks in the cycle into one task.
Prefer a split that removes edges (e.g. one task owns the shared file) over a longer chain.

## 2. Mode
| Dependency edges | Mode | Shape |
| :--- | :--- | :--- |
| none | `independent` | One wave. Every worktree is created from the same base; each task is gated, reviewed, and offered as its own PR. No inter-stage commits. |
| some | `staged` | Topologically layer the tasks; stage *n* holds every task whose dependencies all sit in earlier stages. Use the fewest stages possible. |

Concurrency cap: at most `max_parallel` (from `worktree.sh config`, default **4**) Workers
running at once unless the user sets another limit;
split a larger stage (or wave) into batches.

## 3. Checkpoint report
Lead the report with what needs a human decision; put the detail last. Always in this order
(a single task gets a one-row matrix and no plan block):

**① Decision matrix** — one row per task:

| Task | Findings | Scope | Stage ← deps | Risk | Shared resources | DoD baseline | Critic |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| fix-auth-token | #1, #4 | `src/auth/` · 6 files | 1 | H — auth | — | 1 FAIL-EXPECTED · 2 PASS | 1 accepted |
| add-rate-limit | #2 | `src/api/middleware/` · 3 files | 1 | M | Redis (compose) | 1 NOT-YET · 2 PASS | — |
| migrate-callers | #3 | `src/api/routes/` · 11 files | 2 ← fix-auth-token | M | `routes/index.py` POSSIBLE | 2 PASS · 1 FAIL-EXPECTED | 1 rejected (H) |

- **Scope**: top directories of the whitelist and the file count from
  `check_scope.sh --list <source_worktree> <slug>.wl`.
- **Risk** — the highest that applies:
  - **H**: touches auth/security, a public API, a DB migration, or data deletion; or the
    changed code has no existing tests;
  - **M**: crosses modules, or changes behaviour that existing tests cover;
  - **L**: local, behaviour-preserving, covered by tests.
- **Shared resources**:
  - static: `OVERLAP` / `POSSIBLE` lines from `check_scope.sh --overlap`, lockfiles,
    migrations, common fixtures;
  - runtime, for tasks in the same stage: Docker Compose volumes and networks (shared across
    worktrees, see the spec template's Repo rules), databases, ports, the linked `.venv`.
- **DoD baseline**: class counts from the [DoD dry run](worker-spec-template.md#dod-dry-run).
- **Critic**: accepted/rejected counts, or `skipped` ([plan-critic.md](plan-critic.md)).

**② Decisions for you** — one bullet each, empty section if none: every H-risk task, every
rejected H Critic finding (with the reason), every `FAIL-UNRELATED` DoD, every whitelist
that reaches beyond the files the findings name, and every unresolved `POSSIBLE` overlap.

**③ Execution plan**:
```text
Mode: staged · max parallel 4
Stage 1 (base origin/main 1a2b3c4): fix-auth-token, add-rate-limit       [parallel]
Stage 2 (base sar-stage/1):  migrate-callers ← fix-auth-token
Stage 3 (base sar-stage/2):  drop-legacy-auth ← migrate-callers
Inter-stage: local commits on sar/* and sar-stage/* branches, merges via worktree.sh integrate; no push
```

**④ Gap report and full specs**, with the scratch path of each spec file.

For `staged`, explicitly ask the user to approve the inter-stage local commits and merges.
That approval covers only those local operations; push and PR creation still need their own
consent at close-out.

## 4. Running a stage
`independent` mode is a single stage without steps 4–6.

1. **Create** — `worktree.sh create <slug> --base <stage base>` for each task in the stage
   (stage 1: `default_base`, i.e. omit `--base`; stage *n*: `sar-stage/<n-1>`).
   Stage 2+: dry-run each task's DoD in its new worktree and update the `# baseline:` notes
   per [worker-spec-template.md](worker-spec-template.md#dod-dry-run) before dispatching.
2. **Dispatch** — all Workers of the stage at once, per [dispatch.md](dispatch.md).
3. **Gate + review per task** — `check_scope.sh`, re-run its DoD, review per
   [review-checklist.md](review-checklist.md). Tasks loop independently (max 3 rounds each);
   a slow task does not reset or block the others' rounds.
4. **Barrier + commit** — once every task in the stage is APPROVED, commit each worktree:
   `git -C <wt> add -A && git -C <wt> commit -m "sar(<slug>): <goal>"`.
5. **Integrate** — `worktree.sh integrate <n> --base <stage base> sar/<slug>...`.
   It creates `sar-stage/<n>` in its own worktree and merges each branch with `--no-ff`.
   Exit 1 = merge conflict (conflicting files are listed): the whitelists overlapped after all,
   so fix the plan (re-split, or move a task to a later stage) and ask the user if specs change.
6. **Integration gate** — in the stage worktree, re-run every DoD command of the stage
   (plus the project's full test command if one exists). This catches tasks that pass alone
   but break together. On failure, find the responsible task and send REQUEST_CHANGES to its
   Worker in its own worktree (counts toward its rounds); after APPROVE, commit again,
   `worktree.sh remove --stage <n> --force`, and re-run step 5.
7. Only then create the next stage's worktrees on `sar-stage/<n>`. Each new worktree records
   that as its base, so `check_scope.sh` sees only the task's own changes.

## 5. When a task fails
A task that is still REQUEST_CHANGES after 3 rounds (or is blocked on a non-whitelisted file)
stops the barrier. Report to the user and let them choose:
- **Defer** it and every task that transitively depends on it; integrate the rest of the stage
  and continue with the remaining plan, or
- **Revise** the spec (whitelist, goal, DoD), which needs fresh approval.

Never silently drop a task or its dependents.

## 6. Close-out
- `independent`: offer one PR per task branch.
- `staged`: offer either a single PR from the last `sar-stage/<n>` (contains everything) or
  stacked PRs per stage. Ask; never push without consent.
- Remove task worktrees with `worktree.sh remove <slug>` and stage worktrees with
  `worktree.sh remove --stage <n>`. A stage branch built only from merges is deleted locally
  (task branches are kept unless merged), so push or keep the PR's stage branch first.
