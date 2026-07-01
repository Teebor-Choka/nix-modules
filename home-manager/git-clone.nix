# home-manager/git-clone.nix
# Declaratively clone mutable git repositories into the home directory.
# Each entry is cloned once if its target is absent, then left untouched —
# home-manager does not manage the working copy afterwards.
{ config, lib, pkgs, ... }:
with lib;
{
  options.home.gitClone = mkOption {
    default = {};
    description = ''
      Git repositories to clone, keyed by path relative to $HOME.
      Cloned on activation only when the target does not already exist.
    '';
    example = literalExpression ''
      {
        "Developer/main-repo".url = "git@github.com:yourorg/main-repo.git";
        "Developer/secondary-repo".url = "git@github.com:yourorg/secondary-repo.git";
      }
    '';
    type = types.attrsOf (types.submodule {
      options.url = mkOption {
        type = types.str;
        description = "Git remote URL to clone from.";
      };
    });
  };

  config = mkIf (config.home.gitClone != {}) {
    home.activation.gitClone = hm.dag.entryAfter [ "writeBoundary" ] (
      concatStringsSep "\n" (mapAttrsToList (relPath: repo: ''
        target="$HOME/${relPath}"
        if [ ! -e "$target/.git" ]; then
          $VERBOSE_ECHO "gitClone: ${repo.url} -> ${relPath}"
          $DRY_RUN_CMD ${pkgs.git}/bin/git clone ${escapeShellArg repo.url} "$target" \
            || echo "gitClone: WARNING failed to clone ${relPath}"
        fi
      '') config.home.gitClone)
    );
  };
}
