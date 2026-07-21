# modules/microvms/secrets.nix
# Guest side of the generic secret-injection pipeline (host side: mkSecretsHook in default.nix).
# Imported by guest.nix; no-op unless vmSpec.secrets is non-empty.
#
# The host stages each secret as secrets/secret-<i> in the per-instance working dir, shared
# into the guest at /run/injected-secrets via virtiofs. This service reads each file, places
# it at its declared target, then DELETES the host copy — the plaintext lives on host disk
# only for the few seconds until the guest reads it.
#
# Each vmSpec.secrets entry declares a target with exactly one of:
#   target.filePath = "<path relative to guest home>"   → written as a file
#   target.envName  = "<ENV_VAR_NAME>"                   → written to both environment.d (systemd)
#                                                           and ~/.local/share/injected-env.sh
#                                                           (sourced by all login shells via shellInit)
{
  pkgs,
  lib,
  vmSpec,
  ...
}:
let
  user = vmSpec.user;
  home = "/home/${user}";
  mountBase = "/run/injected-secrets";
  envShFile = "${home}/.local/share/injected-env.sh";

  targets = map (s: s.target) vmSpec.secrets;
  hasEnvTargets = lib.any (t: t.envName != null) targets;

  # Generate one shell snippet per secret, branching on target type at eval time.
  snippets = lib.imap0 (
    i: target:
    let
      src = "${mountBase}/secret-${toString i}";
      idx = "secret[${toString i}]";
    in
    if target.filePath != null then
      let
        dest = "${home}/${target.filePath}";
      in
      ''
        if [ -s "${src}" ]; then
          content=$(cat "${src}")
          rm -f "${src}"
          install -d -o ${user} -g users -m 0700 "$(dirname "${dest}")"
          printf '%s\n' "$content" | install -o ${user} -g users -m 0600 /dev/stdin "${dest}"
          echo "inject-secrets: ${idx} installed at ${target.filePath}"
        else
          echo "inject-secrets: ${idx} not staged — skipping" >&2
        fi
      ''
    else
      # target.envName — write to environment.d (systemd) and injected-env.sh (login shells)
      let
        envDir = "${home}/.config/environment.d";
        confFile = "${envDir}/${target.envName}.conf";
      in
      ''
        if [ -s "${src}" ]; then
          content=$(cat "${src}")
          rm -f "${src}"
          install -d -o ${user} -g users -m 0700 "${envDir}"
          printf '${target.envName}=%s\n' "$content" \
            | install -o ${user} -g users -m 0600 /dev/stdin "${confFile}"
          printf 'export ${target.envName}=%q\n' "$content" >> "${envShFile}"
          echo "inject-secrets: ${idx} installed as ${target.envName}"
        else
          echo "inject-secrets: ${idx} not staged — skipping" >&2
        fi
      ''
  ) targets;

  # Truncate injected-env.sh before snippets append to it (avoids stale entries on re-runs).
  preamble = lib.optionalString hasEnvTargets ''
    install -d -o ${user} -g users -m 0700 "${home}/.local/share"
    install -o ${user} -g users -m 0600 /dev/null "${envShFile}"
  '';
in
lib.mkIf (vmSpec.secrets != [ ]) {
  systemd.services.inject-secrets = {
    description = "Install per-VM secrets from virtiofs share, then wipe host copies";
    wantedBy = [ "multi-user.target" ];
    after = [ "home-manager-${user}.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      umask 077
      ${preamble}
      ${lib.concatStringsSep "\n" snippets}
    '';
  };

  # Source injected-env.sh in all shell sessions (login and interactive) so that env vars
  # delivered via envName targets are visible in SSH sessions, not only systemd user sessions.
  environment.shellInit = lib.optionalString hasEnvTargets ''
    if [ -f "${envShFile}" ]; then
      . "${envShFile}"
    fi
  '';
}
