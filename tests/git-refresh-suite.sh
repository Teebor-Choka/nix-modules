#!/usr/bin/env bash
# Unit tests for home.gitRefresh's per-repo update step (git-refresh-lib.sh), against throwaway
# local git repos — no network. Runs in the Nix build sandbox.
#
# Usage: git-refresh-suite.sh <path-to-git-refresh-lib.sh>
set -uo pipefail
lib=${1:?usage: git-refresh-suite.sh <git-refresh-lib.sh>}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# shellcheck source=/dev/null
. "$lib"

pass=0; fail=0
check() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "✓ $1"; pass=$((pass+1))
  else echo "✗ $1 (want '$2', got '$3')"; fail=$((fail+1)); fi
}
has() { # <label> <needle> <haystack>
  case $3 in *"$2"*) echo "✓ $1"; pass=$((pass+1));; *) echo "✗ $1 (no '$2' in: $3)"; fail=$((fail+1));; esac
}
lacks() { # <label> <needle> <haystack>
  case $3 in *"$2"*) echo "✗ $1 (unexpected '$2' in: $3)"; fail=$((fail+1));; *) echo "✓ $1"; pass=$((pass+1));; esac
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

commit() { # <repo> <file> <content> — add a commit
  printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$2: $3"
}

# new_case <name> — origin (bare) + pusher + consumer clone, all on main with one commit.
new_case() {
  c=$root/$1; mkdir -p "$c"
  git init -q --bare -b main "$c/origin.git"
  git init -q -b main "$c/pusher"
  git -C "$c/pusher" remote add origin "$c/origin.git"
  commit "$c/pusher" base.txt base
  git -C "$c/pusher" push -q origin main
  git clone -q "$c/origin.git" "$c/repo"
}
advance_origin() { # <n> — push n new commits to origin main
  for i in $(seq "$1"); do commit "$c/pusher" "up$i.txt" "up$i"; done
  git -C "$c/pusher" push -q origin main
}
refresh() { # fetch (as the module does), then run the update step; capture both streams
  git -C "$c/repo" fetch -q --prune origin
  out=$(git_refresh_update "$c/repo" "myrepo" 2>&1); rc=$?
}
head_of() { git -C "$c/repo" rev-parse "$1"; }

# 1) clean on default, behind: fast-forwards the checked-out branch.
new_case clean-default; advance_origin 2; refresh
check "clean default: HEAD == origin/main" "$(head_of origin/main)" "$(head_of HEAD)"
check "clean default: exit 0" 0 "$rc"
lacks "clean default: no warning" WARNING "$out"

# 2) dirty on default, behind by 2: fetch only, loud warning, tree and ref untouched.
new_case dirty-default; advance_origin 2
echo wip >> "$c/repo/base.txt"; before=$(head_of HEAD); refresh
check "dirty default: HEAD unchanged" "$before" "$(head_of HEAD)"
check "dirty default: edit preserved" "base
wip" "$(cat "$c/repo/base.txt")"
has "dirty default: warns with count" "myrepo: main is 2 commits behind origin" "$out"
has "dirty default: warning is loud" WARNING "$out"
check "dirty default: warning is one line" 1 "$(printf '%s\n' "$out" | grep -c 'commits behind')"
check "dirty default: exit 0" 0 "$rc"

# 3) dirty on default but already current: no behind-warning.
new_case dirty-current; echo wip >> "$c/repo/base.txt"; refresh
lacks "dirty current default: no behind-warning" "commits behind" "$out"

# 4) dirty on a feature branch, default behind: default ref fast-forwarded, tree untouched.
new_case dirty-feature; advance_origin 3
git -C "$c/repo" checkout -q -b feat; commit "$c/repo" feat.txt feat
echo wip >> "$c/repo/feat.txt"; feat_head=$(head_of HEAD); refresh
check "dirty feature: local main == origin/main" "$(head_of origin/main)" "$(head_of main)"
check "dirty feature: still on feat" feat "$(git -C "$c/repo" branch --show-current)"
check "dirty feature: feat HEAD unchanged" "$feat_head" "$(head_of HEAD)"
check "dirty feature: edit preserved" "feat
wip" "$(cat "$c/repo/feat.txt")"
check "dirty feature: no main files leaked into tree" "no" "$([ -e "$c/repo/up1.txt" ] && echo yes || echo no)"
lacks "dirty feature: no warning" WARNING "$out"

# 5) clean on a feature branch, default behind: default ref fast-forwarded too.
new_case clean-feature; advance_origin 1
git -C "$c/repo" checkout -q -b feat; commit "$c/repo" feat.txt feat; refresh
check "clean feature: local main == origin/main" "$(head_of origin/main)" "$(head_of main)"

# 6) diverged default (checked-out branch is a feature): never force-updated, warns.
new_case diverged; git -C "$c/repo" checkout -q -b feat
commit "$c/repo" local.txt local-main-work
git -C "$c/repo" branch -f main HEAD; advance_origin 1; main_before=$(head_of main); refresh
check "diverged: local main untouched" "$main_before" "$(head_of main)"
has "diverged: warns" "myrepo: main has diverged from origin/main" "$out"
has "diverged: warning is loud" WARNING "$out"
check "diverged: exit 0" 0 "$rc"

# 7) local default ahead of origin (unpushed work): left alone, no warning.
new_case ahead
commit "$c/repo" mine.txt mine; git -C "$c/repo" checkout -q -b feat
main_before=$(head_of main); refresh
check "ahead: local main untouched" "$main_before" "$(head_of main)"
lacks "ahead: no warning" WARNING "$out"

# 8) detached HEAD, default behind: default ref still fast-forwarded, HEAD stays put.
new_case detached; advance_origin 1
git -C "$c/repo" checkout -q --detach; det=$(head_of HEAD); refresh
check "detached: local main == origin/main" "$(head_of origin/main)" "$(head_of main)"
check "detached: HEAD unchanged" "$det" "$(head_of HEAD)"

# 9) no origin/HEAD: default falls back to origin/main.
new_case no-head; advance_origin 1
git -C "$c/repo" remote set-head origin -d >/dev/null
git -C "$c/repo" checkout -q -b feat; refresh
check "no origin/HEAD: main fast-forwarded" "$(head_of origin/main)" "$(head_of main)"

# 10) DRY_RUN_CMD=echo: nothing is modified.
new_case dry; advance_origin 1; git -C "$c/repo" checkout -q -b feat
main_before=$(head_of main); DRY_RUN_CMD=echo refresh; unset DRY_RUN_CMD
check "dry run: main untouched" "$main_before" "$(head_of main)"

echo "git-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
