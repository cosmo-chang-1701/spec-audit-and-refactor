#!/usr/bin/env bash
# Tests for worktree.sh (config, status, provision) and wt.sh.  Run: bash tests/worktree_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W=$SCRIPTS/worktree.sh
WT=$SCRIPTS/wt.sh

section "config: offer_bare_migration"
std=$(make_repo std)
check_eq "standard repo: offered" "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" True
mkdir -p "$std/.agents" && echo '{"offerBareLayout": false}' >"$std/.agents/spec-audit.json"
check_eq "offerBareLayout false: not offered" \
  "$(cd "$std" && bash "$W" config | json_get '["offer_bare_migration"]')" False

repo=$(make_repo bare)
(cd "$repo" && echo SECRET=1 >.env && bash "$SCRIPTS/migrate_to_bare.sh" --apply >/dev/null 2>&1)
check_eq "bare layout: not offered" "$(cd "$repo" && bash "$W" config | json_get '["offer_bare_migration"]')" False

section "config: repo config found from the container root"
mkdir -p "$repo/main/.agents" && echo '{"maxParallel": 2}' >"$repo/main/.agents/spec-audit.json"
check_eq "maxParallel read from main/.agents/spec-audit.json" \
  "$(cd "$repo" && bash "$W" config | json_get '["max_parallel"]')" 2
rm -r "$repo/main/.agents"

section "status"
(cd "$repo" && bash "$W" create clean-task >/dev/null 2>&1 && bash "$W" create dirty-task >/dev/null 2>&1)
check "create provisioned .env" test -f "$repo/sar/clean-task/.env"
echo change >>"$repo/sar/dirty-task/a.txt"
echo new >"$repo/sar/dirty-task/new.txt"
out=$(cd "$repo" && bash "$W" status)
line() { grep "\"slug\":\"$1\"" <<<"$out"; }
check_eq "clean task is clean" "$(line clean-task | json_get '["state"]')" clean
check_eq "dirty task is dirty" "$(line dirty-task | json_get '["state"]')" dirty
check_eq "dirty task: 1 unstaged" "$(line dirty-task | json_get '["unstaged"]')" 1
check_eq "dirty task: 1 untracked" "$(line dirty-task | json_get '["untracked"]')" 1
check_eq "base recorded" "$(line clean-task | json_get '["base"]')" "$(git -C "$repo/main" rev-parse origin/main)"
check_eq "ahead_of_base 0" "$(line clean-task | json_get '["ahead_of_base"]')" 0
check "main worktree not listed" bash -c "! grep -q '\"branch\":\"main\"' <<<'$out'"
(cd "$repo" && bash "$W" status --check >/dev/null); rc=$?
check_eq "--check with a dirty task: exit 1" "$rc" 1
rm -rf "$repo/sar/clean-task"
check_eq "deleted worktree dir is missing" \
  "$(cd "$repo" && bash "$W" status | grep '"clean-task"' | json_get '["state"]')" missing
git -C "$repo/main" worktree prune

section "provision"
rm -f "$repo/sar/dirty-task/.env"
out=$(cd "$repo" && bash "$W" provision sar/dirty-task 2>/dev/null)
check ".env provisioned into an existing worktree" test -f "$repo/sar/dirty-task/.env"
check "provision reports it" grep -q 'copy:.env' <<<"$out"
(cd "$repo" && bash "$W" provision main >/dev/null 2>&1); rc=$?
check_eq "source worktree refused" "$rc" 2
(cd "$repo" && bash "$W" provision "$WORK" >/dev/null 2>&1); rc=$?
check_eq "foreign directory refused" "$rc" 2

section "wt.sh"
git -C "$repo/main" branch local-branch
git -C "$WORK/bare.up" branch remote-branch && git -C "$repo/main" fetch -q origin
(cd "$repo" && bash "$WT" add feat/new >/dev/null 2>&1); rc=$?
check_eq "add new branch" "$rc" 0
check_eq "new branch starts at origin/main" "$(git -C "$repo/feat/new" rev-parse HEAD)" "$(git -C "$repo/main" rev-parse origin/main)"
check "new branch has no upstream" bash -c "! git -C '$repo/feat/new' rev-parse @{u}"
check "new worktree provisioned" test -f "$repo/feat/new/.env"
(cd "$repo" && bash "$WT" add local-branch >/dev/null 2>&1)
check_eq "existing local branch checked out" "$(git -C "$repo/local-branch" branch --show-current)" local-branch
(cd "$repo" && bash "$WT" add remote-branch >/dev/null 2>&1)
check_eq "remote-only branch tracks origin" "$(git -C "$repo/remote-branch" rev-parse --abbrev-ref @{u})" origin/remote-branch
(cd "$repo" && bash "$WT" add sar/x >/dev/null 2>&1); rc=$?
check_eq "sar/ branch refused" "$rc" 2
(cd "$repo/feat/new" && bash "$WT" st --check >/dev/null); rc=$?
check_eq "status --check with a dirty SAR task: exit 1" "$rc" 1
check "status -s lists feat/new" bash -c "cd '$repo' && bash '$WT' st -s | grep -q '^CLEAN   feat/new'"
echo x >"$repo/feat/new/x.txt"
(cd "$repo" && bash "$WT" remove feat/new >/dev/null 2>&1); rc=$?
check_eq "remove dirty worktree refused" "$rc" 2
(cd "$repo" && bash "$WT" remove feat/new --force >/dev/null 2>&1)
check "remove --force drops worktree and empty feat/" test ! -e "$repo/feat"
check "branch kept after remove" git -C "$repo/main" show-ref --verify refs/heads/feat/new
(cd "$repo" && bash "$WT" remove main >/dev/null 2>&1); rc=$?
check_eq "default-branch worktree refused" "$rc" 2
(cd "$std" && bash "$WT" list >/dev/null 2>&1); rc=$?
check_eq "standard layout refused" "$rc" 2

section "standard layout lifecycle still works (regression)"
rm -r "$std/.agents"
t=$(cd "$std" && bash "$W" create task-one 2>/dev/null | json_get '["worktree_path"]')
check_eq "task worktree at <parent>/worktrees/<repo>/<slug>" "$t" "$WORK/worktrees/std/task-one"
echo change >>"$t/a.txt"
printf 'a.txt\n' >"$WORK/whitelist"
check "check_scope passes for a whitelisted change" bash "$SCRIPTS/check_scope.sh" "$t" "$WORK/whitelist"
git -C "$t" commit -qam "sar(task-one): change"
(cd "$std" && bash "$W" integrate 1 --base HEAD sar/task-one >/dev/null 2>&1); rc=$?
check_eq "integrate exits 0" "$rc" 0
check_eq "status lists task and stage" "$(cd "$std" && bash "$W" status | python3 -c 'import json,sys; print(sorted({json.loads(l)["kind"] for l in sys.stdin}))')" \
  "['stage', 'task']"
(cd "$std" && bash "$W" remove --stage 1 >/dev/null 2>&1 && bash "$W" remove task-one >/dev/null 2>&1); rc=$?
check_eq "remove stage and task" "$rc" 0
check_eq "no SAR worktrees left" "$(cd "$std" && bash "$W" list)" ""

finish
