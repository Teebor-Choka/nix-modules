# home-manager/git-refresh.nix
# Companion to `home.gitClone` (git-clone.nix): gitClone clones each repo once and never touches
# it again; this module keeps those checkouts current. On every activation it updates each existing
# clone to its latest upstream — SAFELY. It always `fetch`es, but only fast-forwards the checked-out
# branch when the working tree is clean; a dirty, diverged, or detached repo is fetched-only and left
# untouched, so local work is never discarded. Read-only repos always land on the latest default-branch
# tip; repos you work in advance only when it's a trivial fast-forward.
#
# Runs after the `gitClone` activation node and in the SAME activation shell, so it inherits the SSH
# env (GIT_SSH_COMMAND + launchctl SSH_AUTH_SOCK) that node exports — fetches over SSH just work,
# and a failure is non-fatal (warns), exactly like gitClone's own clone step.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    mkIf
    optionalString
    concatStringsSep
    mapAttrsToList
    ;
  cfg = config.home.gitRefresh;
  git = "${pkgs.git}/bin/git";
in
{
  options.home.gitRefresh.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Update every home.gitClone checkout to its latest upstream on activation (safe fast-forward only; never discards local work).";
  };

  config = mkIf (cfg.enable && config.home.gitClone != { }) {
    # Each repo runs in its own backgrounded subshell so the (slow, network-bound) fetches all
    # run in parallel; `wait` blocks until they finish. The subshell also scopes `target`, so the
    # parallel jobs don't race on a shared variable.
    home.activation.gitRefresh = lib.hm.dag.entryAfter [ "gitClone" ] (
      concatStringsSep "\n" (
        mapAttrsToList (relPath: repo: ''
          (
            target="$HOME/${relPath}"
            if [ -d "$target/.git" ]; then
              $DRY_RUN_CMD ${git} -C "$target" fetch ${
                optionalString (repo.depth != null) "--depth ${toString repo.depth}"
              } --prune --quiet origin \
                || echo "gitRefresh: WARNING fetch failed for ${relPath}"
              if [ -z "$(${git} -C "$target" status --porcelain 2>/dev/null)" ]; then
                $DRY_RUN_CMD ${git} -C "$target" merge --ff-only --quiet '@{u}' 2>/dev/null \
                  || $VERBOSE_ECHO "gitRefresh: ${relPath} not fast-forwardable — left as-is"
              else
                $VERBOSE_ECHO "gitRefresh: ${relPath} has local changes — fetched only"
              fi
            fi
          ) &
        '') config.home.gitClone
      )
      + "\nwait\n"
    );
  };
}
