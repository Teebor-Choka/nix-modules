#!/usr/bin/env bash
# Unit test for home-manager/agent-plugins-lib.nix: marketplace.json -> normalized plugin records.
# One pure `nix eval` (no VM), then jq comparisons. Run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
fix="$PWD/tests/fixtures/agent-plugins"
fail=0
check() { # label want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

out=$(nix eval --impure --json --expr "
  let l = import ./home-manager/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; };
      ps = l.normalize { src = \"$fix\"; exclude = [ \"skipme\" ]; };
  in { names = map (p: p.name) ps; byName = builtins.listToAttrs (map (p: { name = p.name; value = p; }) ps); }")
get() { jq -c "$1" <<<"$out"; }

check "plugin names, exclude applied" '["solo","multi","bundle"]' "$(get '.names')"
check "skills-mode skill names" '["a","b"]' "$(get '.byName.multi.skillNames')"
check "dir-mode skill names from readDir" '["one","two"]' "$(get '.byName.bundle.skillNames')"
check "dir-mode ignores non-directories" 'false' "$(get '.byName.bundle.skillNames | index("README.md") != null')"
check "dir-mode root" "\"$fix/bundle\"" "$(get '.byName.bundle.root')"
check "skills-mode has no root" 'null' "$(get '.byName.solo.root')"
check "skill source path" "\"$fix/tools/solo\"" "$(get '.byName.solo.skills.solo')"
check "version from metadata" '"1.2.0"' "$(get '.byName.solo.version')"
check "author from marketplace owner" '{"name":"Fixture Owner"}' "$(get '.byName.solo.author')"
exit $fail
