#!/usr/bin/env bash
# Scope gate: verify every file the Worker touched is covered by the whitelist.
#
# Usage: check_scope.sh <worktree> <whitelist-file> [--base <ref>]
#
# Changed set = committed since base  ∪  staged/unstaged vs HEAD  ∪  untracked.
# Renames count as delete + add, so both paths must be allowed.
# Base defaults to the fork point recorded by `worktree.sh create`.
#
# Whitelist format (one pattern per line, paths relative to repo root):
#   src/auth/**          # ** spans directories
#   src/auth/*.ts        # *  stays within one directory
#   tests/auth/          # trailing / means the whole directory
#   !src/auth/secrets.ts # leading ! forbids, overriding positive matches
#   # comments and blank lines are ignored
#
# Exit: 0 = all in scope, 1 = violations (listed on stdout), 2 = usage error.
set -euo pipefail

readonly REGEX_SPECIALS='.[]\^$+(){}|'

die() { printf 'check_scope: %s\n' "$*" >&2; exit 2; }

# Glob -> anchored ERE. `**/` = zero or more dirs, `**` = anything, `*` / `?` stay in one segment.
glob_to_regex() {
  local glob=$1 out="" i c next
  [[ $glob == */ ]] && glob+="**"
  for ((i = 0; i < ${#glob}; i++)); do
    c=${glob:i:1} next=${glob:i+1:1}
    if [[ $c == "*" && $next == "*" ]]; then
      if [[ ${glob:i+2:1} == "/" ]]; then out+="(.*/)?"; ((i += 2)); else out+=".*"; ((i += 1)); fi
    elif [[ $c == "*" ]]; then out+="[^/]*"
    elif [[ $c == "?" ]]; then out+="[^/]"
    elif [[ $REGEX_SPECIALS == *"$c"* ]]; then out+="\\$c"
    else out+=$c
    fi
  done
  printf '^%s$' "$out"
}

(($# >= 2)) || { sed -n '2,17p' "$0" >&2; exit 2; }
worktree=$1 whitelist=$2; shift 2
base=""
while (($#)); do
  case $1 in
    --base) [[ $# -ge 2 ]] || die "--base needs a value"; base=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -d $worktree ]] || die "worktree not found: $worktree"
[[ -r $whitelist ]] || die "whitelist not readable: $whitelist"
git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || die "not a git worktree: $worktree"

if [[ -z $base ]]; then
  base_file="$(git -C "$worktree" rev-parse --absolute-git-dir)/sar-base"
  [[ -r $base_file ]] || die "no recorded base; pass --base <ref>"
  base=$(<"$base_file")
fi
git -C "$worktree" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base '$base' not found"

allow=() deny=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
  [[ -z $line ]] && continue
  if [[ $line == !* ]]; then deny+=("$(glob_to_regex "${line#!}")"); else allow+=("$(glob_to_regex "$line")"); fi
done <"$whitelist"
((${#allow[@]})) || die "whitelist has no allow patterns"

mapfile -t changed < <(
  {
    git -C "$worktree" diff --name-only --no-renames "$base" HEAD
    git -C "$worktree" diff --name-only --no-renames HEAD
    git -C "$worktree" ls-files --others --exclude-standard
  } | sort -u
)

violations=0
for file in "${changed[@]}"; do
  [[ -z $file ]] && continue
  ok=0
  for re in "${allow[@]}"; do [[ $file =~ $re ]] && { ok=1; break; }; done
  for re in "${deny[@]}"; do [[ $file =~ $re ]] && { ok=0; break; }; done
  if ((ok)); then printf 'IN-SCOPE   %s\n' "$file"; else printf 'VIOLATION  %s\n' "$file"; ((violations += 1)); fi
done

printf '\n%d changed file(s), %d violation(s) (base %s)\n' "${#changed[@]}" "$violations" "${base:0:12}"
((violations == 0))
