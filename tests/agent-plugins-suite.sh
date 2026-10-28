#!/usr/bin/env bash
# Unit test for home-manager/agent-plugins-lib.nix: marketplace.json -> normalized plugin records.
# Pure `nix eval`, no VM. Run from the repo root: bash tests/agent-plugins-suite.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fix="$PWD/tests/fixtures/agent-plugins"
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
ev() { nix eval --impure --json --expr "
  let lib = (import <nixpkgs> {}).lib;
      l = import ./home-manager/agent-plugins-lib.nix { inherit lib; };
      ps = l.normalize { src = \"$fix\"; exclude = [ \"skipme\" ]; };
  in $1"; }

check "plugin names, exclude applied" '["solo","multi","bundle"]' "$(ev 'map (p: p.name) ps')"
check "skills-mode skill names" '["a","b"]' "$(ev '(builtins.head (builtins.filter (p: p.name == "multi") ps)).skillNames')"
check "dir-mode skill names from readDir" '["one","two"]' "$(ev '(builtins.head (builtins.filter (p: p.name == "bundle") ps)).skillNames')"
check "dir-mode root" "\"$fix/bundle\"" "$(ev '(builtins.head (builtins.filter (p: p.name == "bundle") ps)).root')"
check "skills-mode has no root" 'null' "$(ev '(builtins.head (builtins.filter (p: p.name == "solo") ps)).root')"
check "skill source path" "\"$fix/tools/solo\"" "$(ev '(builtins.head (builtins.filter (p: p.name == "solo") ps)).skills.solo')"
check "version from metadata" '"1.2.0"' "$(ev '(builtins.head (builtins.filter (p: p.name == "solo") ps)).version')"
exit $fail
