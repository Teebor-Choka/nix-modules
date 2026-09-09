# home-manager/git-refresh.nix
# Companion to `home.gitClone` (git-clone.nix): gitClone clones each repo once and never touches
# it again; this module keeps those checkouts current. On every activation it updates each existing
# clone to its latest upstream — SAFELY. It always `fetch`es, but only fast-forwards the checked-out
# branch when the working tree is clean; a dirty, diverged, or detached repo is fetched-only and left
# untouched, so local work is never discarded. Repos marked `readOnly` are instead hard-reset to the
# upstream tip on every activation (see git-clone.nix); repos you work in advance only on a trivial
# fast-forward.
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
    description = "Update every home.gitClone checkout to its latest upstream on activation (safe fast-forward; readOnly repos are hard-reset to the upstream tip).";
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
              # Heal shallow clones: a `--depth n` fetch of an advanced branch grafts away the
              # ancestry, so `merge --ff-only` sees no common base and refuses a clean advance.
              # `--unshallow` (only valid on an actually-shallow repo) completes the history once,
              # after which every refresh is a normal full fetch.
              unshallow=""
              [ -f "$target/.git/shallow" ] && unshallow="--unshallow"
              before="$(${git} -C "$target" rev-parse --short HEAD 2>/dev/null)"
              $DRY_RUN_CMD ${git} -C "$target" fetch $unshallow --prune --quiet origin \
                || echo "gitRefresh: WARNING fetch failed for ${relPath}"
              ${
                if repo.readOnly then
                  # Read-only mirror: force to the upstream tip. `reset --hard` needs only the
                  # fetched `@{u}` ref, so it lands on the tip even across force-pushes and shallow
                  # clones, and never blocks on tracked-file edits. Untracked files are left alone.
                  ''
                    $DRY_RUN_CMD ${git} -C "$target" reset --hard --quiet '@{u}' 2>/dev/null \
                      || echo "gitRefresh: WARNING reset failed for ${relPath}"
                    after="$(${git} -C "$target" rev-parse --short HEAD 2>/dev/null)"
                    if [ "$before" = "$after" ]; then
                      echo "gitRefresh: ${relPath} up to date ($after)"
                    else
                      echo "gitRefresh: ${relPath} reset $before -> $after"
                    fi
                  ''
                else
                  ''
                    if [ -z "$(${git} -C "$target" status --porcelain 2>/dev/null)" ]; then
                      if $DRY_RUN_CMD ${git} -C "$target" merge --ff-only --quiet '@{u}' 2>/dev/null; then
                        after="$(${git} -C "$target" rev-parse --short HEAD 2>/dev/null)"
                        if [ "$before" = "$after" ]; then
                          echo "gitRefresh: ${relPath} up to date ($after)"
                        else
                          echo "gitRefresh: ${relPath} fast-forward $before -> $after"
                        fi
                      else
                        echo "gitRefresh: ${relPath} not fast-forwardable — left as-is"
                      fi
                    else
                      echo "gitRefresh: ${relPath} has local changes — fetched only"
                    fi
                  ''
              }
            fi
          ) &
        '') config.home.gitClone
      )
      + "\nwait\n"
    );
  };
}
