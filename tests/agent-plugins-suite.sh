#!/usr/bin/env bash
# Unit test for home-manager/agent-plugins-lib.nix: marketplace.json -> normalized plugin records.
# jq comparisons over the normalized records.
#   agent-plugins-suite.sh                  one pure `nix eval` (no VM); run anywhere
#   agent-plugins-suite.sh <json> <fixdir>  records already evaluated (the flake check, in the sandbox)
set -euo pipefail
fail=0
check() { # label want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

if [ $# -eq 2 ]; then
  out=$(cat "$1")
  fix=$2
else
  cd "$(dirname "$0")/.."
  fix="$PWD/tests/fixtures/agent-plugins"
  out=$(nix eval --impure --json --expr "
    let l = import ./home-manager/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; };
        ps = l.normalize { src = \"$fix\"; exclude = [ \"skipme\" ]; };
    in { names = map (p: p.name) ps; byName = builtins.listToAttrs (map (p: { name = p.name; value = p; }) ps); }")
fi
get() { jq -c "$1" <<<"$out"; }

check "plugin names, exclude applied" '["solo","multi","bundle","unversioned"]' "$(get '.names')"
check "skills-mode skill names, linked by frontmatter name" '["a","b","odd-named"]' "$(get '.byName.multi.skillNames')"
check "frontmatter-named skill points at its dir" "\"$fix/multi/odd\"" "$(get '.byName.multi.skills["odd-named"]')"
check "dir-mode skill names from readDir" '["one","two"]' "$(get '.byName.bundle.skillNames')"
check "dir-mode ignores non-directories" 'false' "$(get '.byName.bundle.skillNames | index("README.md") != null')"
check "dir-mode root" "\"$fix/bundle\"" "$(get '.byName.bundle.root')"
check "skills-mode has no root" 'null' "$(get '.byName.solo.root')"
check "skill source path" "\"$fix/tools/solo\"" "$(get '.byName.solo.skills.solo')"
check "version from metadata" '"1.2.0"' "$(get '.byName.solo.version')"
check "no version when the marketplace gives none" 'null' "$(get '.byName.unversioned.version')"
check "author from marketplace owner" '{"name":"Fixture Owner"}' "$(get '.byName.solo.author')"
exit $fail
