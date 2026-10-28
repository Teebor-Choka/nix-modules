# home-manager/agent-plugins.nix
# Deliver every plugin of one or more skills repos to the agent harnesses from the repos'
# marketplace manifests. The skill dirs stay the single source of truth; a plugin is a thin
# bundle over them (see agent-plugins-lib.nix). opt-in: home.agentPlugins.enable.
#   Claude Code: one closure per plugin, loaded with a repeated `--plugin-dir` (shell alias), so
#                skills surface namespaced (`plugin:skill`).
#   oh-my-pi, OpenCode, Codex: every skill linked under `skillsTarget` (~/.agents/skills).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mkForce
    concatMap
    concatStringsSep
    mapAttrsToList
    listToAttrs
    nameValuePair
    removePrefix
    unique
    ;
  cfg = config.home.agentPlugins;
  agentLib = import ./agent-plugins-lib.nix { inherit lib; };
  plugins = concatMap (m: agentLib.normalize { inherit (m) src exclude; }) cfg.marketplaces;

  # Skills-mode plugins have no directory of their own: build one that links the skill dirs.
  closure =
    p:
    if p.root != null then
      p.root
    else
      pkgs.runCommand "plugin-${p.name}" { } ''
        mkdir -p $out/.claude-plugin $out/skills
        cp ${
          pkgs.writeText "plugin.json" (builtins.toJSON { inherit (p) name version description; })
        } $out/.claude-plugin/plugin.json
        ${concatStringsSep "\n" (mapAttrsToList (n: path: "ln -s ${path} $out/skills/${n}") p.skills)}
      '';

  closures = map closure plugins;
  pluginDirs = map toString closures ++ cfg.extraPluginDirs;
  skillsRel = removePrefix "${config.home.homeDirectory}/" cfg.skillsTarget;
in
{
  options.home.agentPlugins = {
    enable = mkEnableOption "delivering marketplace plugins to the agent harnesses";

    marketplaces = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            src = mkOption {
              type = types.str;
              description = "Store path of a skills repo (a flake input) holding `.claude-plugin/marketplace.json`.";
            };
            exclude = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Plugin names delivered elsewhere (for example by `home.swePlugin`).";
            };
          };
        }
      );
      default = [ ];
    };

    extraPluginDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Further `--plugin-dir` values, for plugins wired by their own module.";
    };

    skillsTarget = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.agents/skills";
      description = "Cross-harness skills dir read by oh-my-pi, OpenCode, and Codex.";
    };

    skillNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = unique (concatMap (p: p.skillNames) plugins);
      description = "Read-only: every skill delivered here. Feed to `home.skillLink.exclude`.";
    };

    pluginDirs = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = pluginDirs;
      description = "Read-only: the closures given to Claude Code via `--plugin-dir`.";
    };
  };

  config = mkIf cfg.enable {
    # mkForce: this alias also carries home.swePlugin's dir (via extraPluginDirs), so it wins.
    home.shellAliases.claude = mkForce (
      "claude " + concatStringsSep " " (map (d: "--plugin-dir ${d}") pluginDirs)
    );

    home.file = listToAttrs (
      concatMap (
        p: mapAttrsToList (n: path: nameValuePair "${skillsRel}/${n}" { source = path; }) p.skills
      ) plugins
    );
  };
}
