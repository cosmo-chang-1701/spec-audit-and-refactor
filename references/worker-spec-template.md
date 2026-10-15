# Worker Spec Template

The Lead fills one spec per task and passes it **verbatim** as the Worker's prompt.
Everything the Worker needs must be in here — it has no access to the Lead's conversation.
Save the Whitelist section to a file too; `check_scope.sh` consumes it.

```markdown
# Worker Spec: <task-slug>

## Role
You are the Worker (implementer) in a Lead-Worker workflow. You modify code ONLY inside
the worktree below and ONLY files matched by the Whitelist. The Lead will reject any
change outside it. Do not commit, push, merge, rebase, or touch other worktrees/branches.

- Worktree (your working root): <absolute path>
- Branch: sar/<task-slug> (already checked out; base <short sha>)
- Stage: <n>/<total> · Base includes: <slugs of earlier tasks already merged in, or "none">

Other Workers may be editing other files in other worktrees at the same time. Never read,
write, or run commands in any worktree but your own.

## Repo rules
<Rules from the repo's AGENTS.md / CLAUDE.md that apply to this task (how and where to run
 tests, lint, type checks; required flags; language rules), known repo pitfalls from the
 Lead's memory, and any `worker_notes` — one bullet each.>
- Provisioned files listed by `worktree.sh create` (`.env*` copies, `.venv` symlinks into the
  source worktree) are secret or shared: never edit or delete them, never install packages
  into a linked venv.
- Format and lint only with the versions the repo pins (e.g. `pre-commit run <hook> --files
  <files you changed>`), never with another locally installed formatter, and never over the
  whole tree — a different version rewrites unrelated files.
- Docker Compose derives its project name from the directory name, which is the same in
  every worktree (e.g. `app/`), so all worktrees share one set of images, volumes, and
  networks. Use only `docker compose run --rm ...`; never `build`, `up`, or `down`. If the
  DoD needs a rebuilt image (Dockerfile or dependency changes), stop and report.

## Goal
<One or two sentences: the outcome, not the steps.>

## Context
<Audit findings this task resolves, each with file:line and why it matters.
 Relevant conventions (naming, error handling, test layout) observed in the codebase.
 If this task depends on earlier ones: what they changed that you can now rely on
 (new APIs, renamed symbols, changed behaviour), with file:line in your base.>

## Whitelist
<One glob per line, repo-relative. `**` spans dirs, `*` one segment, trailing `/` = whole dir,
 `!pattern` forbids. Include test files you expect the Worker to add or edit.>

    src/payments/**
    tests/payments/**
    !src/payments/vendor/**

## Forbidden
- Files outside the Whitelist (including lockfiles, CI config, formatter config) unless listed.
- New dependencies, public API signature changes, or disabling/skipping tests and lint rules
  — unless explicitly allowed here: <exceptions or "none">.

## Steps (suggested, not mandatory)
1. <...>
2. <...>

## Definition of Done
Every command must exit 0 when run from the worktree root:

    <test command, e.g. pytest tests/payments -q>
    <lint command, e.g. ruff check src/payments tests/payments>
    <type check / build, if applicable>

Plus these behavioural criteria:
- <e.g. "duplicate charge path at src/payments/charge.py:88 is unreachable; covered by a test">

## If blocked
If the DoD cannot be met without touching a non-whitelisted file, STOP and report the file
and the reason instead of editing it.

## Report back (final message)
1. Summary of changes per file (one line each).
2. Full output (or tail) of each DoD command.
3. Anything skipped, assumed, or left for follow-up.
```

## Lead checklist before dispatching
- [ ] Slug is kebab-case and matches the worktree branch.
- [ ] Whitelist is the minimum set; tests are included.
- [ ] Every DoD item is a runnable command or an objectively checkable statement, and
      follows the Repo rules (working directory, flags, allowed tools).
- [ ] Repo rules cover the repo's agent docs, relevant pitfalls, and every `worker_notes` entry.
- [ ] The task is in the execution plan; its stage, dependencies, and base ref match it,
      and its whitelist does not overlap any other task in the same stage.
- [ ] The user has approved this spec (Phase 2 checkpoint).
