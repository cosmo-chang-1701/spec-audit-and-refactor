#!/usr/bin/env bash
# Tests for check_scope.sh (gate, --list, --overlap).  Run: bash tests/check_scope_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C=$SCRIPTS/check_scope.sh

repo=$(make_repo scope)
mkdir -p "$repo/src/pay/vendor" "$repo/src/auth" "$repo/tests/pay"
for f in src/pay/charge.py src/pay/vendor/lib.py src/auth/token.py tests/pay/test_charge.py src/shared.py; do
  echo x >"$repo/$f"
done
git -C "$repo" add -A && git -C "$repo" commit -qm files
printf 'src/pay/**\ntests/pay/\n!src/pay/vendor/**\n# comment\n\n' >"$WORK/pay.wl"
printf 'src/auth/*.py\nsrc/shared.py\n' >"$WORK/auth.wl"
printf 'src/**\n' >"$WORK/src.wl"
printf 'tests/auth/**\n' >"$WORK/new.wl"
rc() { "$@" >/dev/null 2>&1; echo $?; }

section "gate"
base=$(git -C "$repo" rev-parse HEAD)
check_eq "no changes: exit 0" "$(rc bash "$C" "$repo" "$WORK/pay.wl" --base "$base")" 0
echo y >>"$repo/src/pay/charge.py"; echo n >"$repo/tests/pay/test_new.py"
check_eq "whitelisted edit + untracked file: exit 0" "$(rc bash "$C" "$repo" "$WORK/pay.wl" --base "$base")" 0
echo y >>"$repo/src/pay/vendor/lib.py"
out=$(bash "$C" "$repo" "$WORK/pay.wl" --base "$base"); r=$?
check_eq "denied path: exit 1" "$r" 1
check "denied path reported" grep -q '^VIOLATION  src/pay/vendor/lib.py$' <<<"$out"
git -C "$repo" checkout -q -- src/pay/vendor/lib.py
echo y >>"$repo/src/shared.py"
check_eq "path outside whitelist: exit 1" "$(rc bash "$C" "$repo" "$WORK/pay.wl" --base "$base")" 1
git -C "$repo" checkout -q -- . && rm "$repo/tests/pay/test_new.py"
check_eq "missing base without record: exit 2" "$(rc bash "$C" "$repo" "$WORK/pay.wl")" 2

section "--list"
out=$(bash "$C" --list "$repo" "$WORK/pay.wl" 2>"$WORK/err"); r=$?
check_eq "exit 0" "$r" 0
check_eq "tracked files in scope, deny applied" "$out" $'src/pay/charge.py\ntests/pay/test_charge.py'
check "count on stderr" grep -q '^2 tracked file(s) in scope$' "$WORK/err"
check_eq "no matches is not an error" "$(rc bash "$C" --list "$repo" "$WORK/new.wl")" 0
printf '!src/**\n' >"$WORK/deny-only.wl"
check_eq "deny-only whitelist: exit 2" "$(rc bash "$C" --list "$repo" "$WORK/deny-only.wl")" 2
check_eq "not a work tree: exit 2" "$(rc bash "$C" --list "$WORK" "$WORK/pay.wl")" 2

section "--overlap"
check_eq "disjoint whitelists: exit 0" "$(rc bash "$C" --overlap "$repo" "$WORK/pay.wl" "$WORK/auth.wl")" 0
out=$(bash "$C" --overlap "$repo" "$WORK/pay.wl" "$WORK/auth.wl")
check "disjoint whitelists: no POSSIBLE" bash -c '! grep -q POSSIBLE <<<"$1"' _ "$out"
out=$(bash "$C" --overlap "$repo" "$WORK/pay.wl" "$WORK/auth.wl" "$WORK/src.wl"); r=$?
check_eq "shared tracked files: exit 1" "$r" 1
check "OVERLAP names both whitelists" grep -qF "OVERLAP   src/pay/charge.py  ($WORK/pay.wl, $WORK/src.wl)" <<<"$out"
check "denied file is not an overlap" bash -c '! grep -q "OVERLAP   src/pay/vendor" <<<"$1"' _ "$out"
check "literal path vs wildcard: POSSIBLE" grep -qF "POSSIBLE  src/shared.py ($WORK/auth.wl) ~ src/** ($WORK/src.wl)" <<<"$out"
printf 'tests/au*\n' >"$WORK/prefix.wl"
out=$(bash "$C" --overlap "$repo" "$WORK/new.wl" "$WORK/prefix.wl"); r=$?
check_eq "only untracked-file overlap: exit 0" "$r" 0
check "shared literal prefix: POSSIBLE" grep -qF "POSSIBLE  tests/auth/** ($WORK/new.wl) ~ tests/au* ($WORK/prefix.wl)" <<<"$out"
check_eq "no whitelist: exit 2" "$(rc bash "$C" --overlap "$repo")" 2
check_eq "unreadable whitelist: exit 2" "$(rc bash "$C" --overlap "$repo" "$WORK/missing.wl")" 2

finish
