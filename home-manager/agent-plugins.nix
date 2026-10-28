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
    mkMerge
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
          pkgs.writeText "plugin.json" (
            builtins.toJSON (
              {
                inherit (p) name description;
              }
              // lib.optionalAttrs (p.version != null) { inherit (p) version; }
              // lib.optionalAttrs (p.author != null) { inherit (p) author; }
            )
          )
        } $out/.claude-plugin/plugin.json
        ${concatStringsSep "\n" (mapAttrsToList (n: path: "ln -s ${path} $out/skills/${n}") p.skills)}
      '';

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
      default = [ ];
      description = ''
        Every `--plugin-dir` Claude Code is launched with. Lists merge, so a module that wires
        its own plugin (home.swePlugin) appends its dir here; this module owns the alias.
      '';
    };
  };

  config = mkMerge [
    (mkIf (cfg.pluginDirs != [ ]) {
      home.shellAliases.claude =
        "claude " + concatStringsSep " " (map (d: "--plugin-dir ${d}") cfg.pluginDirs);
    })

    (mkIf cfg.enable {
      home.agentPlugins.pluginDirs = map (p: toString (closure p)) plugins;

      home.file = listToAttrs (
        concatMap (
          p: mapAttrsToList (n: path: nameValuePair "${skillsRel}/${n}" { source = path; }) p.skills
        ) plugins
      );
    })
  ];
}
