# home-manager/skill-link.nix
# Symlink SKILL.md-containing dirs from source trees flat into a target dir (default ~/.claude/skills),
# so a tool that expects <target>/<name>/SKILL.md (and does not scan recursively) finds them. Typically
# paired with `home.gitClone` source clones; runs after the `gitClone` activation node.
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
    escapeShellArg
    concatStringsSep
    ;
  cfg = config.home.skillLink;
in
{
  options.home.skillLink = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };
    target = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.claude/skills";
    };
    sources = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Absolute dirs scanned recursively for SKILL.md (later source wins on name clash).";
    };
  };

  config = mkIf cfg.enable {
    home.activation.skillLink = lib.hm.dag.entryAfter [ "gitClone" ] ''
      target=${escapeShellArg cfg.target}
      if [ -e "$target/.git" ]; then
        echo "skillLink: ERROR $target is a git checkout — back it up and remove it, then re-run." >&2
        exit 1
      fi
      $DRY_RUN_CMD mkdir -p "$target"
      $DRY_RUN_CMD find "$target" -maxdepth 1 -type l -delete   # prune managed symlinks; real files untouched
      for src in ${concatStringsSep " " (map escapeShellArg cfg.sources)}; do
        [ -d "$src" ] || { echo "skillLink: WARNING missing source $src" >&2; continue; }
        ${pkgs.findutils}/bin/find "$src" -name '.*' -prune -o -type f -name SKILL.md -print | while IFS= read -r f; do
          dir=$(dirname "$f"); name=$(basename "$dir"); link="$target/$name"
          [ -L "$link" ] && echo "skillLink: WARNING '$name' overridden by $dir" >&2
          $DRY_RUN_CMD ln -sfn "$dir" "$link"
        done
      done
    '';
  };
}
