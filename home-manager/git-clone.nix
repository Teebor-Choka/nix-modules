# home-manager/git-clone.nix
# Declaratively clone mutable git repositories into the home directory.
# Each entry is cloned once if its target is absent, then left untouched —
# home-manager does not manage the working copy afterwards.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{
  options.home.gitClone = mkOption {
    default = { };
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
    type = types.attrsOf (
      types.submodule {
        options.url = mkOption {
          type = types.str;
          description = "Git remote URL to clone from.";
        };
        options.depth = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Shallow-clone depth. When set, clones with --depth <n> --single-branch.";
        };
      }
    );
  };

  config = mkIf (config.home.gitClone != { }) {
    home.activation.gitClone = hm.dag.entryAfter [ "writeBoundary" ] (
      ''
        export GIT_SSH_COMMAND="${
          if pkgs.stdenv.isDarwin then "/usr/bin/ssh" else "${pkgs.openssh}/bin/ssh"
        }"
        ${optionalString pkgs.stdenv.isDarwin ''
          if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
            SSH_AUTH_SOCK=$(/bin/launchctl asuser "$(id -u)" /bin/launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)
            export SSH_AUTH_SOCK
          fi
        ''}
        if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
          echo "gitClone: WARNING SSH_AUTH_SOCK not set — SSH URL clones will fail."
        fi
      ''
      + concatStringsSep "\n" (
        mapAttrsToList (relPath: repo: ''
          target="$HOME/${relPath}"
          if [ ! -e "$target/.git" ]; then
            $VERBOSE_ECHO "gitClone: ${repo.url} -> ${relPath}"
            $DRY_RUN_CMD ${pkgs.git}/bin/git clone ${
              optionalString (repo.depth != null) "--depth ${toString repo.depth} --single-branch"
            } ${escapeShellArg repo.url} "$target" \
              || echo "gitClone: WARNING failed to clone ${relPath}"
          fi
        '') config.home.gitClone
      )
    );
  };
}
