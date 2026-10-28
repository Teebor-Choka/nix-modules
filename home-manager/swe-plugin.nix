# home-manager/swe-plugin.nix
# Wire the swe-process policy-gate plugin into the agent harnesses from a single
# built plugin closure (skills-private's `packages.swe-process-plugin`). The
# consumer passes the built package; this module installs the per-harness overlay
# each agent reads at startup. All four overlays call the same `hooks/gate.sh`;
# the discipline lives in `.agents/policy`, never here. opt-in: home.swePlugin.enable.
{
  config,
  lib,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mkMerge
    elem
    listToAttrs
    removePrefix
    ;
  cfg = config.home.swePlugin;
  # The plugin closure is itself a plugin dir (.claude-plugin/plugin.json, hooks/,
  # skills/), so its store path is Claude Code's `--plugin-dir` value verbatim.
  pluginDir = "${cfg.package}";
  # home.file keys are home-relative; skillsTarget is absolute.
  skillsRel = removePrefix "${config.home.homeDirectory}/" cfg.skillsTarget;
in
{
  options.home.swePlugin = {
    enable = mkEnableOption "the swe-process policy-gate plugin across agent harnesses";

    package = mkOption {
      type = types.package;
      description = ''
        The built swe-process plugin closure: a plugin directory holding
        `.claude-plugin/plugin.json`, `hooks/`, and `skills/`. Pass
        `inputs.skills-private.packages.$\{system}.swe-process-plugin`.
      '';
    };

    agents = mkOption {
      type = types.listOf (
        types.enum [
          "claude"
          "opencode"
          "omp"
          "codex"
        ]
      );
      default = [
        "claude"
        "opencode"
        "omp"
      ];
      description = ''
        Which harnesses to wire the policy-gate hook into. `codex` is opt-in
        because enabling it makes home-manager manage `~/.codex/config.toml`
        (Codex has no config-fragment include), which clobbers any hand-written
        Codex config not routed through `codexBaseConfig`.
      '';
    };

    skills = mkOption {
      type = types.listOf types.str;
      default = [
        "implement"
        "triage"
        "find-bug"
      ];
      description = ''
        Plugin skills to expose to the non-Claude harnesses under `skillsTarget`.
        Claude Code reads them from the plugin dir instead, so they are not linked
        into `~/.claude/skills` here (no double-listing).
      '';
    };

    skillsTarget = mkOption {
      type = types.str;
      default = config.home.agentPlugins.skillsTarget;
      description = "Cross-harness skills dir read by oh-my-pi, OpenCode, and Codex.";
    };

    codexBaseConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Existing `~/.codex/config.toml` body to preserve when `codex` is wired;
        the policy-gate `[[hooks.PreToolUse]]` block is appended to it.
      '';
    };

    pluginDir = mkOption {
      type = types.str;
      readOnly = true;
      default = pluginDir;
      description = ''
        Read-only: the plugin closure path. Launch Claude Code with
        `--plugin-dir $\{config.home.swePlugin.pluginDir}` from the harness command
        (also exported as the `SWE_PLUGIN_DIR` session variable).
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.package != null;
          message = "home.swePlugin.enable is set but home.swePlugin.package is unset.";
        }
      ];

      # Expose the plugin path to every harness launcher (and the microVM template
      # built from this config, which bakes it into the given launch command).
      home.sessionVariables.SWE_PLUGIN_DIR = pluginDir;

      # Skills for the non-Claude harnesses: one symlink per skill under the
      # neutral `~/.agents/skills` dir they scan.
      home.file = listToAttrs (
        map (s: {
          name = "${skillsRel}/${s}";
          value.source = "${cfg.package}/skills/${s}";
        }) cfg.skills
      );
    }

    # Claude Code: the plugin dir is a launch modifier, not a config file. Join the shared
    # `--plugin-dir` list that home.agentPlugins turns into the alias; the given launch command /
    # microVM template uses the `pluginDir` option (or SWE_PLUGIN_DIR) directly.
    (mkIf (elem "claude" cfg.agents) {
      home.agentPlugins.pluginDirs = [ pluginDir ];
    })

    # oh-my-pi: link the pre-hook overlay into the agent hooks dir.
    (mkIf (elem "omp" cfg.agents) {
      home.file.".omp/agent/hooks/pre/swe-process.mjs".source =
        "${cfg.package}/hooks/omp/policy-gate.mjs";
    })

    # OpenCode: drop the guardrail module into the user plugins dir.
    (mkIf (elem "opencode" cfg.agents) {
      home.file.".config/opencode/plugin/swe-process.mjs".source =
        "${cfg.package}/hooks/opencode/guard.mjs";
    })

    # Codex: user-level PreToolUse hook. Codex has no fragment include, so the
    # whole config.toml is managed; prior config is preserved via codexBaseConfig.
    (mkIf (elem "codex" cfg.agents) {
      home.file.".codex/config.toml".text = ''
        ${cfg.codexBaseConfig}
        [[hooks.PreToolUse]]
        matcher = "shell"
        command = "${cfg.package}/hooks/gate.sh"
        timeout = 10
      '';
    })
  ]);
}
