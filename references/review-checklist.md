# PR Review Checklist (Lead)

Review the task diff, not the whole repo. Start with the stat; read the full diff only when
it is small, otherwise file by file (append `-- <path>`), so a large change does not flood the
context:

```bash
base=$(cat "$(git -C <worktree> rev-parse --absolute-git-dir)/sar-base")
git -C <worktree> diff "$base" --stat
git -C <worktree> diff "$base" [-- <path>]
```

In later rounds, review only what changed since the previous round: note the files the
findings named and re-read just those, plus any new entries in `--stat`.

Only proceed to review once the gates pass: `check_scope.sh` exits 0 **and** you re-ran
every DoD command yourself in the worktree through `run_logged.sh` (never trust the Worker's
report alone).

## What to check, in priority order
1. **Correctness** — logic errors, unhandled edge cases (empty/null/boundary/concurrency),
   error paths that swallow failures, resource leaks.
2. **Spec conformance** — every Goal / DoD criterion met; nothing beyond the Goal
   (unrequested refactors, renamed symbols, reformatted unrelated lines).
3. **Tests** — new behaviour is covered; tests assert outcomes (not just "no exception");
   no tests deleted, skipped, or weakened to make the DoD pass.
4. **Safety** — no secrets, no disabled lint rules / type ignores without justification,
   no new dependencies unless the spec allowed them.
5. **Consistency** — matches surrounding naming, error-handling, and comment style.

Do not report style nits a linter would catch, or pre-existing issues outside the diff
(record those as follow-up audit findings instead).

## Verdict format

```markdown
## Review: <task-slug> — round <n>/3
Verdict: APPROVE | REQUEST_CHANGES

Gates: scope ✅/❌ · DoD ✅/❌ (<commands re-run>)

Findings (blocking first):
1. [blocking] path/to/file.py:42 — <what is wrong> → <required change>
2. [non-blocking] path/to/file.py:77 — <suggestion>
```

## Loop rules
- REQUEST_CHANGES → send the Worker the numbered blocking findings plus the original spec
  (same worktree, same whitelist), and store the findings as the task's `open_findings` in
  `state.json`. Max **3 rounds**; after that, stop and escalate to the user
  with the remaining findings.
- A finding that requires a file outside the whitelist is a spec change: ask the user before
  widening the whitelist. With parallel tasks, also check the new file is not in another
  task's whitelist for the same stage.
- Parallel tasks are reviewed and counted separately; one task's rounds never block or reset
  another's.
- APPROVE (`independent` mode) → summarise for the user and ask whether to commit / push /
  open a PR. Never do these without explicit consent.
- APPROVE (`staged` mode) → hold the task at the stage barrier. When the whole stage is
  approved, commit locally under the checkpoint approval (no push), integrate, and run the
  integration gate per [execution-plan.md](execution-plan.md). An integration-gate failure
  becomes a REQUEST_CHANGES round for the responsible task.
