# modules/microvms/default.nix
# Host-side module (darwin or NixOS) — declares custom.microvms options,
# configures the linux-builder on darwin, and provides the `vm` helper.
{
  config,
  pkgs,
  lib,
  ...
}:
with lib;
let
  cfg = config.custom.microvms;
  flakeDir = config.custom.flakeDir;
  # vmSubmodule's own `config` arg shadows this outer one; alias it so submodule defaults can
  # still reach HOST options (custom.username / custom.microvmDefaults).
  hostConfig = config;

  vmNames = attrNames cfg;
  vmNamesStr = concatStringsSep " " vmNames;

  # Launch-time trust tokens the `vm` helper can grant. Single source of truth: feeds both the
  # `trust.default` option enum (Nix) and the baked `VALID_TRUST_TOKENS` (bash).
  trustTokens = [
    "secrets"
    "agent"
    "shares"
  ];

  # Bake a bash assoc-array body ("[name]=v …") for the vm helper, one entry per VM.
  bakeMap = f: concatStringsSep " " (mapAttrsToList (name: spec: "[${name}]=${f spec}") cfg);

  # Bake vsock port mapping for the Linux vm helper (name → port; empty when agent forwarding off)
  vmPortsStr = bakeMap (spec: toString (spec.vsockPort or ""));
  # Whether the host `vm` helper should bridge the SSH agent for each VM (name → 0|1)
  vmForwardAgentStr = bakeMap (spec: if spec.forwardSshAgent then "1" else "0");
  vmPersistentStr = bakeMap (spec: if spec.persistent then "1" else "0");
  # Per-VM default trust grant (name → csv of tokens; empty = grant nothing). Quoted so an empty
  # value or a multi-token csv survives the bash assoc-array literal.
  vmTrustDefaultStr = bakeMap (spec: ''"${concatStringsSep "," spec.trust.default}"'');
  # Whether each VM was built with the launch-mount slot (name → 0|1); gates `vm run --mount`.
  vmLaunchMountStr = bakeMap (spec: if spec.launchMount then "1" else "0");
  # Per-VM default mount host dir (name → abs path or ""); mounted when the `shares` token is granted.
  vmDefaultMountStr = bakeMap (
    spec: ''"${if spec.defaultMount == null then "" else spec.defaultMount}"''
  );

  # Platform-derived home directory prefix for option defaults
  homePrefix = if pkgs.stdenv.isDarwin then "/Users" else "/home";

  # Stable, deterministic locally-administered MAC from the VM name
  nameMac =
    name:
    let
      h = builtins.hashString "sha256" name;
      o = i: substring (i * 2) 2 h;
    in
    "02:${o 1}:${o 2}:${o 3}:${o 4}:${o 5}";

  # Deterministic host-side vsock port / CID for a VM, derived from its name so the consumer
  # needn't hand-assign (and hand-deconflict) ports. Range 20000–29999 clears privileged and
  # common service ports plus the macOS ephemeral range (49152+); a per-host assertion (see
  # config below) catches the rare hash collision. Setting vsockPort explicitly overrides this.
  hexDigit =
    c:
    {
      "0" = 0;
      "1" = 1;
      "2" = 2;
      "3" = 3;
      "4" = 4;
      "5" = 5;
      "6" = 6;
      "7" = 7;
      "8" = 8;
      "9" = 9;
      "a" = 10;
      "b" = 11;
      "c" = 12;
      "d" = 13;
      "e" = 14;
      "f" = 15;
    }
    .${c};
  hexToInt = s: foldl' (acc: c: acc * 16 + hexDigit c) 0 (stringToCharacters s);
  autoVsockPort =
    name:
    let
      n = hexToInt (substring 0 6 (builtins.hashString "sha256" name));
    in
    20000 + (n - (n / 10000) * 10000); # 20000 + (n mod 10000)

  # ── Secret injection (host side) ────────────────────────────────────────────
  # Generic KeePassXC → virtiofs → guest placer. vfkit/AVF allows only ONE virtio-vsock
  # device (used by the SSH agent), so secrets are delivered via a virtiofs share: at launch
  # the host fetches each secret from KeePassXC and stages it as secrets/secret-<i> in the
  # per-instance working dir (auto-shared into the guest at /run/injected-secrets — see
  # guest.nix). The guest service (secrets.nix) places each at its declared target then
  # DELETES the host copy — plaintext is on host disk only for the few seconds until read.
  #
  # Read the KDBX passphrase from the host OS secret store to stdout (exit 1 if missing).
  #   macOS → Keychain (`security`); Linux → Secret Service (`secret-tool`, served by KeePassXC
  #   or GNOME Keyring). `keychainDbPass` is the Keychain service name / secret-tool `service`
  #   attribute. Host-agnostic so `vm up` works from either a macOS or a Linux control node.
  fetchPassphrase =
    keychainDbPass: db:
    if pkgs.stdenv.isDarwin then
      ''
        pw=$(security find-generic-password -w -s ${keychainDbPass} 2>/dev/null) || {
          echo "secret fetch: macOS Keychain item '${keychainDbPass}' not found." >&2
          echo "  It must hold the passphrase for KDBX '${db}'." >&2
          echo "  Create it with:" >&2
          echo "    security add-generic-password -s ${keychainDbPass} -a \$USER -w" >&2
          exit 1; }
      ''
    else
      ''
        pw=$(${pkgs.libsecret}/bin/secret-tool lookup service ${keychainDbPass} 2>/dev/null) || {
          echo "secret fetch: Secret Service item (service=${keychainDbPass}) not found." >&2
          echo "  It must hold the passphrase for KDBX '${db}'." >&2
          echo "  Store it with:" >&2
          echo "    secret-tool store --label='${keychainDbPass}' service ${keychainDbPass}" >&2
          exit 1; }
      '';

  # Fetch the configured attribute of a KeePassXC entry and print it to stdout. The content
  # (JSON blob or bare token) is opaque here; placement is declared via secret.target.
  keepassxcFetch =
    cli:
    {
      db,
      keychainDbPass,
      entry,
      attribute ? "password",
      ...
    }:
    ''
      ${fetchPassphrase keychainDbPass db}
      printf '%s\n' "$pw" | ${cli} \
        show -q -a ${attribute} "${db}" "${entry}"
    '';

  # Build the host pre-launch shell that fetches each secret and stages it atomically.
  # CWD = per-instance working dir; "secrets/" is the virtiofs source for the guest.
  # $name is the VM name (a shell var set by _vm_prepare).
  mkSecretsHook =
    spec:
    let
      fetchOne =
        i: secret:
        let
          idx = toString i;
        in
        ''
          fetch_secret_${idx}() {
          ${keepassxcFetch spec.keepassxcCli (builtins.removeAttrs secret [ "target" ])}
          }
          rm -f secrets/secret-${idx} secrets/secret-${idx}.new
          if ( fetch_secret_${idx} ) > secrets/secret-${idx}.new 2>/dev/null \
              && [ -s secrets/secret-${idx}.new ]; then
            chmod 600 secrets/secret-${idx}.new
            mv secrets/secret-${idx}.new secrets/secret-${idx}
            echo "→ secret[${idx}] staged for $name"
          else
            rm -f secrets/secret-${idx}.new
            echo "⚠  secret[${idx}] fetch failed for $name — will be skipped in guest"
          fi
        '';
    in
    ''
      install -d -m 700 secrets
      umask 077
    ''
    + concatStringsSep "\n" (imap0 fetchOne spec.secrets);

  vmSubmodule = { name, config, ... }: {
    options = {
      hypervisor = mkOption {
        type = types.str;
        default = if pkgs.stdenv.isDarwin then "vfkit" else "qemu";
        description = "microvm.nix hypervisor backend (vfkit on macOS, qemu on Linux)";
      };
      vcpu = mkOption {
        type = types.int;
        default = 12;
      };
      mem = mkOption {
        type = types.int;
        default = 10240;
      };
      homeSize = mkOption {
        type = types.int;
        default = 10240;
      };
      storeSize = mkOption {
        type = types.int;
        default = 20480;
      };
      user = mkOption {
        type = types.str;
        default = hostConfig.custom.username;
      };
      timeZone = mkOption {
        type = types.str;
        default = hostConfig.custom.microvmDefaults.timeZone;
      };
      locale = mkOption {
        type = types.str;
        default = hostConfig.custom.microvmDefaults.locale;
      };
      autologin = mkOption {
        type = types.bool;
        default = true;
      };
      mac = mkOption {
        type = types.str;
        default = nameMac name;
        description = "Guest NIC MAC address (auto-derived; override if needed)";
      };
      hmModules = mkOption {
        type = types.listOf types.path;
        default = [ ../../home-manager/home.nix ];
        description = ''
          Base home-manager modules imported into every guest (generic, user-agnostic).
          Defaults to the shared base (home-manager/home.nix).
          Per-user layers (scripts, dotfiles, git identity, etc.) are added via extraHmModules.
        '';
      };
      extraHmModules = mkOption {
        type = types.listOf types.path;
        default = [ ];
      };

      # ── Guest nixpkgs / networking knobs (defaults are the generic library defaults) ──────
      overlays = mkOption {
        type = types.listOf (mkOptionType {
          name = "nixpkgs-overlay";
          check = lib.isFunction;
          merge = lib.mergeOneOption;
        });
        default = [ ];
        description = "nixpkgs overlays applied inside this guest (e.g. a plugins overlay). Empty by default.";
      };
      allowUnfree = mkOption {
        type = types.bool;
        default = false;
        description = "allowUnfree inside this guest.";
      };
      extraPackages = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _: [ ];
        description = "Extra guest system packages, as a function of the guest pkgs: `pkgs: [ pkgs.foo ]`.";
        example = literalExpression "pkgs: [ pkgs.gh pkgs.htop ]";
      };
      ntpServers = mkOption {
        type = types.listOf types.str;
        default = [ "pool.ntp.org" ];
        description = "chrony NTP servers.";
      };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
      substituters = mkOption {
        type = types.listOf types.str;
        default = [
          "https://cache.nixos.org/"
          "https://nix-community.cachix.org"
        ];
      };
      trustedPublicKeys = mkOption {
        type = types.listOf types.str;
        default = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCUSids="
        ];
      };
      sshConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra ~/.ssh/config content (Host alias blocks for key selection)";
      };
      sshPubKeys = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Public key files to place in ~/.ssh/ (filename → content)";
        example = literalExpression ''{ "work.pub" = "ssh-ed25519 AAAA…"; }'';
      };
      guestSSH = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Run sshd inside the guest for host→guest access (debugging / verification). Networking
            is usermode NAT, so reach it via a host port-forward to the guest IP. Password auth is
            disabled; authorize access via guestSSH.authorizedKeys.
          '';
        };
        authorizedKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Public keys authorized for the guest user's sshd (used when guestSSH.enable).";
          example = literalExpression ''[ "ssh-ed25519 AAAA… user@host" ]'';
        };
      };
      forwardSshAgent = mkOption {
        type = types.bool;
        default = true;
        description = "Forward the host's SSH agent ($SSH_AUTH_SOCK) into the guest over virtio-vsock.";
      };
      vsockPort = mkOption {
        type = types.nullOr types.int;
        default = if config.forwardSshAgent then autoVsockPort name else null;
        defaultText = literalExpression "auto-derived from the VM name (20000–29999) when forwardSshAgent, else null";
        description = ''
          Host-side virtio-vsock port (also the guest CID under qemu) for the forwarded SSH agent.
          Defaults to a deterministic per-name port so ports need not be hand-assigned; set it
          explicitly to pin a port. Must be unique among the VMs on a single host.
        '';
      };
      extraShares = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              source = mkOption {
                type = types.str;
                description = "Absolute host path to share";
              };
              mountPoint = mkOption {
                type = types.str;
                description = "Absolute guest mount path";
              };
              tag = mkOption {
                type = types.str;
                default = "";
                description = "virtiofs tag (auto-derived from basename(mountPoint) when empty)";
              };
            };
          }
        );
        default = [ ];
        description = "Extra host directories to share into this VM (virtiofs, read-write). Opt-in per VM.";
        example = literalExpression ''
          [{ source = "/Users/alice/Projects"; mountPoint = "/home/alice/Projects"; }]
        '';
      };
      vfkitExtraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      extraModules = mkOption {
        type = types.listOf types.unspecified;
        default = [ ];
      };

      # ── Non-persistent /home backing ──────────────────────────────────────────
      homeBacking = mkOption {
        type = types.enum [
          "tmpfs"
          "disk"
          "auto"
        ];
        default = "auto";
        description = ''
          Backing for the per-instance, non-persistent /home. "tmpfs" = guest RAM; "disk" = a
          per-instance ext4 image in the launch's working dir, wiped on exit; "auto" = tmpfs when
          mem > 2*homeSize, else disk. Each `vm up` runs in its own working dir, so multiple
          instances of the same VM can run concurrently.
        '';
      };

      # ── Persistence ───────────────────────────────────────────────────────────
      persistent = mkOption {
        type = types.bool;
        default = false;
        description = ''
          false (default): per-instance ephemeral state (home + store overlay in the launch's
          working dir / RAM), concurrent instances, wiped on exit.
          true: home.img and a writable store.img live at the VM's fixed base dir and survive
          across boots (package cache persists); single-instance (a lock refuses a second
          concurrent launch, since a shared rw image would corrupt). Forces homeBacking=disk.
        '';
      };

      # ── Read-only store base ──────────────────────────────────────────────────
      storeBacking = mkOption {
        type = types.enum [
          "host"
          "image"
        ];
        default = "host";
        description = ''
          Read-only Nix store base (shared safely across concurrent instances — it is immutable).
          "host" shares the host /nix/store via virtiofs (no per-VM store image → faster `vm up`;
          native on Linux; exposes the whole host store read-only). "image" builds a per-VM EROFS
          image containing only this VM's closure (less exposure, slower rebuilds). The writable
          store overlay is always per-instance RAM (rootfs tmpfs).
        '';
      };

      # ── Generic host-side launch hook ─────────────────────────────────────────
      # Mechanism-agnostic escape hatch: shell run by the `vm` helper just before the VM
      # starts. Higher-level concerns (credential agents, RAM-disk mounts, secret fetching)
      # live in the CONSUMER, not this library. In scope: $name, $state_dir, $OS, and
      # $MICROVM_HOME_IMG (disk mode). Contract: background helpers should write their PID to
      # "$state_dir/<x>.pid" and listen on "$state_dir/<x>.sock"; the helper's trap kills every
      # "$state_dir/*.pid" and removes every "$state_dir/*.sock" on exit.
      hostPreLaunch = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Shell executed on the host by the `vm` helper immediately before launching this VM.
          Use it to wire secret/mount mechanisms (e.g. a vsock credential agent) without this
          library knowing about them. Guest-side pieces go through extraModules.
        '';
      };

      # ── Launch-time trust ─────────────────────────────────────────────────────
      # What this VM is granted when `vm up/run` is invoked with no trust flag. Sandboxes are
      # isolated by default ([] = grant nothing); a launch flag (--trusted/--isolated/--trust)
      # overrides this. Long-term / pre-configured VMs set a default so common workflows need no
      # flag. Tokens: `secrets` (inject declared secrets) and `agent` (forward the host SSH agent).
      # `extraShares` forwarding stays build-time for now.
      trust.default = mkOption {
        type = types.listOf (types.enum trustTokens);
        default = [ ];
        description = ''
          Capabilities granted to this VM when launched without a trust flag. `[]` (default) grants
          nothing — secrets withheld, host SSH agent not forwarded, and defaultMount not mounted —
          unless the launch grants them (`vm run --trust secrets,agent,shares`, or `--trusted`). Set
          e.g. `[ "secrets" "agent" "shares" ]` on a VM that should inject secrets, reach the host
          agent, and mount its defaultMount by default. A VM that clones over SSH at first boot
          (home.gitClone) needs `agent` here.
        '';
        example = literalExpression ''[ "secrets" "agent" "shares" ]'';
      };

      # ── Launch mount slot ────────────────────────────────────────────────────────
      # Build the guest with a per-instance virtiofs slot (guest path = launchMountPoint). Empty
      # (isolated) by default; a launch points its source at a host dir — either `vm run --mount
      # <dir>` (explicit, this launch) or the VM's `defaultMount` when the `shares` trust token is
      # granted. No source → the slot stays an empty per-instance dir, so nothing host-side leaks.
      launchMount = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Give this VM a launch-mount slot (at launchMountPoint), so a host directory can be shared
          into the guest — via `vm run --mount <hostdir>` or the VM's defaultMount under `shares`
          trust. Nothing is mounted unless one of those applies. Set false to omit the slot entirely
          (then --mount is rejected and defaultMount is unusable).
        '';
      };
      launchMountPoint = mkOption {
        type = types.str;
        default = "/mnt/host";
        description = "Guest path where the launch-mount slot is mounted (RW).";
      };
      defaultMount = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Absolute host directory mounted into the guest (at launchMountPoint) when a launch grants
          the `shares` trust token (via `trust.default`, `--trust shares`, or `--trusted`). `vm run
          --mount <dir>` overrides it for a single launch; `--isolated` withholds it. Requires
          launchMount = true.
        '';
        example = literalExpression ''"/Users/alice/Projects"'';
      };

      # ── Secret injection (KeePassXC → virtiofs → guest) ───────────────────────
      # When non-empty, the host stages each secret before launch and the guest places it
      # at its target then wipes the host copy (see secrets.nix). The /run/injected-secrets
      # share is added automatically. Works from a macOS or Linux control node: the KDBX
      # passphrase is read from the macOS Keychain (`security`) or the Linux Secret Service
      # (`secret-tool`), and keepassxcCli defaults per platform.
      secrets = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              db = mkOption {
                type = types.str;
                description = "Path to the KDBX file (host shell expands $HOME).";
              };
              keychainDbPass = mkOption {
                type = types.str;
                description = "Host secret-store key holding the KDBX passphrase: macOS Keychain service name, or Linux secret-tool `service` attribute.";
              };
              entry = mkOption {
                type = types.str;
                description = ''KeePassXC entry path; UI '>' group separator becomes '/' (e.g. "Network/Services/ClaudeCode").'';
              };
              attribute = mkOption {
                type = types.str;
                default = "password";
                description = "KeePassXC attribute to read (default: the entry password).";
              };
              target = mkOption {
                description = "Where the fetched secret is placed in the guest — set exactly one of filePath / envName.";
                type = types.submodule {
                  options = {
                    filePath = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Path relative to the guest home to write the secret to.";
                    };
                    envName = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Environment variable name to expose the secret as (login shells + systemd).";
                    };
                  };
                };
              };
            };
          }
        );
        default = [ ];
        description = "Secrets fetched from KeePassXC at launch and injected into the guest.";
        example = literalExpression ''
          [{ db = "$HOME/work.kdbx"; keychainDbPass = "keepassxc-work";
             entry = "Network/Services/ClaudeCode"; target.filePath = ".claude/.credentials.json"; }]
        '';
      };
      keepassxcCli = mkOption {
        type = types.str;
        default =
          if pkgs.stdenv.isDarwin then
            "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
          else
            "keepassxc-cli";
        description = "Path to the keepassxc-cli binary used to fetch secrets on the host (macOS app bundle path / `keepassxc-cli` on PATH for Linux).";
      };
    };
  };

  # Per-VM host launch hook dispatch (a shell `case` body). Stages secrets (when declared)
  # then runs the consumer-provided hostPreLaunch shell for the VM being started.
  # Multi-line, hence a case (not an assoc map).
  hostPreLaunchDispatch = concatStringsSep "\n" (
    mapAttrsToList (
      name: spec:
      let
        # Secret staging is gated on the launch-time grant ($GRANT, set by vm_up/vm_run). When
        # `secrets` is not granted, nothing is staged and the guest's inject-secrets no-ops.
        secretsBlock = optionalString (spec.secrets != [ ]) ''
          if _in_list secrets $GRANT; then
          ${mkSecretsHook spec}
          else
            echo "→ secrets withheld from ${name} (not trusted this launch)"
          fi
        '';
        combined = concatStringsSep "\n" (
          filter (s: s != "") [
            secretsBlock
            spec.hostPreLaunch
          ]
        );
      in
      optionalString (combined != "") ''
              ${name})
        ${combined}
                ;;''
    ) cfg
  );
in
{
  options.custom = {
    flakeDir = mkOption {
      type = types.str;
      default = "${homePrefix}/${config.custom.username}/.config/nix";
      description = "Absolute path to the nix flake directory (used by vm/builder helpers and rebuild-me alias)";
    };
    microvmDefaults = {
      timeZone = mkOption {
        type = types.str;
        default = "Europe/Zurich";
      };
      locale = mkOption {
        type = types.str;
        default = "en_US.UTF-8";
      };
    };
    microvms = mkOption {
      type = types.attrsOf (types.submodule vmSubmodule);
      default = { };
      description = "Development microVMs (vfkit on macOS, qemu/KVM on Linux)";
    };
  };

  config = mkIf (cfg != { }) (mkMerge [
    # ── Common (both platforms) ────────────────────────────────────────────────
    {
      # Each secret target must set exactly one of filePath / envName.
      assertions =
        concatLists (
          mapAttrsToList (
            name: spec:
            imap0 (i: s: {
              assertion = (s.target.filePath != null) != (s.target.envName != null);
              message = "microVM '${name}': secrets[${toString i}].target must set exactly one of 'filePath' or 'envName'.";
            }) spec.secrets
          ) cfg
        )
        # defaultMount needs the launch-mount slot to exist.
        ++ mapAttrsToList (name: spec: {
          assertion = spec.defaultMount == null || spec.launchMount;
          message = "microVM '${name}': defaultMount is set but launchMount = false — enable launchMount.";
        }) cfg
        # vsockPort is a per-host resource (host-side socat port + guest CID); the auto-derived
        # default can (rarely) collide. Two VMs on the SAME host must not share one.
        ++ (
          let
            activePorts = mapAttrsToList (_: s: s.vsockPort) (
              filterAttrs (_: s: s.forwardSshAgent && s.vsockPort != null) cfg
            );
          in
          [
            {
              assertion = activePorts == unique activePorts;
              message = "microVMs on this host have colliding vsockPorts (${
                concatMapStringsSep ", " toString activePorts
              }). Set an explicit unique vsockPort on the conflicting VM(s).";
            }
          ]
        );

      environment.systemPackages = [
        pkgs.socat

        (pkgs.writeShellScriptBin "nix-vm" ''
          set -euo pipefail

          FLAKE="${flakeDir}"
          DEFINED_VMS="${vmNamesStr}"
          OS=$(uname -s)

          # SSH-agent relay lifecycle helpers (pure; unit-tested in tests/agent-bridge-suite.sh).
          ${builtins.readFile ./agent-bridge-lib.sh}

          # sandy orchestration: box identity + registry helpers (pure; unit-tested in tests/sandy-suite.sh).
          ${builtins.readFile ./sandy-lib.sh}

          # sandy reverse-tunnel: the shared host tunnel-sshd port (KEEP IN SYNC with guest.nix
          # sandyTunnelPort) and absolute openssh binaries — sshd's re-exec requires an absolute path,
          # so we bake store paths rather than rely on PATH.
          SANDY_TSSHPORT=20022
          SANDY_SSHD="${pkgs.openssh}/bin/sshd"
          SANDY_SSH="${pkgs.openssh}/bin/ssh"
          SANDY_SSHKEYGEN="${pkgs.openssh}/bin/ssh-keygen"
          SANDY_SSHADD="${pkgs.openssh}/bin/ssh-add"

          # vsock port per VM name — baked in at Nix build time (Linux qemu bridge)
          declare -A VM_VSOCK_PORTS=(${vmPortsStr})

          # Per-VM persistence (0 = ephemeral per-instance, 1 = persistent single-instance)
          declare -A VM_PERSISTENT=(${vmPersistentStr})

          # Per-VM SSH-agent forwarding (1 = bridge the host agent, 0 = skip)
          declare -A VM_FORWARD_AGENT=(${vmForwardAgentStr})

          # Per-VM default trust grant (name → csv of tokens; empty = grant nothing at launch)
          declare -A VM_TRUST_DEFAULT=(${vmTrustDefaultStr})

          # Per-VM launch-mount slot presence (1 = built with the mount share; enables --mount/defaultMount)
          declare -A VM_LAUNCH_MOUNT=(${vmLaunchMountStr})

          # Per-VM default mount host dir (empty = none); used when the `shares` token is granted.
          declare -A VM_DEFAULT_MOUNT=(${vmDefaultMountStr})

          # Trust tokens the launcher can grant (baked from the same Nix list as the option enum).
          VALID_TRUST_TOKENS="${concatStringsSep " " trustTokens}"
          # Per-launch state set by _parse_launch_opts and read by _resolve_grant / _vm_prepare.
          # Init empty so `set -u` never trips on them.
          #   GRANT        resolved trust tokens (space-separated); gates secret staging + agent bridge
          #   MOUNT_SRC    --mount host dir (abs) or defaultMount; empty = no mount
          #   CPU/MEM_OVERRIDE  --cpu/--mem for this launch; empty = keep the VM's built-in vcpu/mem
          #   mode/csv     trust flag mode + explicit --trust csv;  env_prefix  --env exports (run)
          GRANT=""; MOUNT_SRC=""; CPU_OVERRIDE=""; MEM_OVERRIDE=""; TUN_PASSTHROUGH=0
          mode=default; csv=""; env_prefix=""

          # Path to the standalone Tailscale CLI (macsys cask). Only used by --tun-passthrough (Darwin).
          SANDY_TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

          # Validate a positive integer argument (rc 2 otherwise). $1 flag-name $2 value.
          _pos_int() {
            case "$2" in
              "" | *[!0-9]*) echo "✗ $1 needs a positive integer, got '$2'" >&2; return 2 ;;
            esac
            [ "$2" -gt 0 ] || { echo "✗ $1 must be > 0" >&2; return 2; }
            printf '%s' "$2"
          }

          # Build an `export KEY=VALUE; ` snippet for --env; validates KEY, quotes VALUE. rc 2 on error.
          _env_export() {
            local kv=$1 k v
            case "$kv" in
              *=*) k=''${kv%%=*}; v=''${kv#*=} ;;
              *)   echo "✗ --env expects KEY=VALUE, got '$kv'" >&2; return 2 ;;
            esac
            [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "✗ --env invalid variable name: '$k'" >&2; return 2; }
            printf 'export %s=%q; ' "$k" "$v"
          }

          # Resolve a --mount argument to an absolute directory (rc 2 if it isn't a directory).
          _abs_dir() {
            local d=$1
            [ -d "$d" ] || { echo "✗ --mount: not a directory: $d" >&2; return 2; }
            ( cd "$d" && pwd )
          }

          # Apply per-launch edits to the copied runner in one pass (portable — no `sed -i`). Args are
          # `sed -e` clauses; each launch-time knob (per-instance MAC, mount source, cpu/mem) is baked
          # into the runner as a literal, so all three are just substitutions on the same file.
          _patch_runner() {
            local r="$INST_DIR/microvm-run"
            sed -E "$@" "$r" > "$r.new" && chmod u+x "$r.new" && mv "$r.new" "$r"
          }

          # Space-list membership test: _in_list <needle> <item…>
          _in_list() { local n=$1; shift; local x; for x in $*; do [ "$x" = "$n" ] && return 0; done; return 1; }

          # Print (comma-separated) the IPv4 subnet-route CIDRs the host's tailscale currently carries —
          # the ranges a guest needs an explicit route for under --tun-passthrough (tailnet peer IPs in
          # 100.64.0.0/10 already work via gvproxy). Empty if tailscale is down / advertises none. The
          # JSON parsing lives in a file (tailscale-routes.py) so no column-0 Python breaks this string.
          _tailscale_routes() {
            [ -x "$SANDY_TS" ] || return 0
            "$SANDY_TS" status --json 2>/dev/null | python3 ${./tailscale-routes.py} 2>/dev/null
          }

          # Apply the VM's defaultMount as the mount source when `shares` is granted and no explicit
          # --mount was given. Explicit --mount (MOUNT_SRC already set) and --isolated (no `shares`)
          # both leave MOUNT_SRC untouched. Reads GRANT + VM_DEFAULT_MOUNT.
          _resolve_default_mount() {
            local name=$1
            [ -z "$MOUNT_SRC" ] || return 0
            _in_list shares "$GRANT" || return 0
            local d="''${VM_DEFAULT_MOUNT[$name]:-}"
            [ -n "$d" ] && MOUNT_SRC="$d"
            return 0
          }

          # Print the resolved launch state (VM_DEBUG_GRANT dry-run). Pass env_prefix to include the
          # `env:` line (vm run); omit it (vm up has no --env).
          _debug_grant() {
            echo "grant: ''${GRANT:-<none>}"
            [ $# -gt 0 ] && echo "env: ''${1:-<none>}"
            echo "mount: ''${MOUNT_SRC:-<none>}"
            echo "cpu: ''${CPU_OVERRIDE:-<default>}"
            echo "mem: ''${MEM_OVERRIDE:-<default>}"
            echo "tun-passthrough: $([ "$TUN_PASSTHROUGH" = 1 ] && echo on || echo off)"
          }

          # Parse the leading launch options shared by `vm up` and `vm run`; sets mode/csv/MOUNT_SRC/
          # CPU_OVERRIDE/MEM_OVERRIDE (+ env_prefix for run) and leaves the residual args (name + any
          # command) in PARSE_REST. $1 = context ("up" rejects --env; "run" accepts it). rc 2 on error.
          _parse_launch_opts() {
            local ctx=$1; shift
            mode=default; csv=""; MOUNT_SRC=""; CPU_OVERRIDE=""; MEM_OVERRIDE=""; env_prefix=""; TUN_PASSTHROUGH=0
            while [ $# -gt 0 ]; do
              case "$1" in
                --trusted)  mode=trusted;  shift ;;
                --isolated) mode=isolated; shift ;;
                --trust)    mode=set; csv=''${2:?'--trust needs a comma-separated token list'}; shift 2 ;;
                --trust=*)  mode=set; csv=''${1#--trust=}; shift ;;
                --mount)    MOUNT_SRC=$(_abs_dir "''${2:?'--mount needs a host directory'}") || return 2; shift 2 ;;
                --mount=*)  MOUNT_SRC=$(_abs_dir "''${1#--mount=}") || return 2; shift ;;
                --cpu)      CPU_OVERRIDE=$(_pos_int --cpu "''${2:?'--cpu needs a positive integer'}") || return 2; shift 2 ;;
                --cpu=*)    CPU_OVERRIDE=$(_pos_int --cpu "''${1#--cpu=}") || return 2; shift ;;
                --mem)      MEM_OVERRIDE=$(_pos_int --mem "''${2:?'--mem needs a positive integer (MiB)'}") || return 2; shift 2 ;;
                --mem=*)    MEM_OVERRIDE=$(_pos_int --mem "''${1#--mem=}") || return 2; shift ;;
                --tun-passthrough) TUN_PASSTHROUGH=1; shift ;;
                --env | --env=*)
                  [ "$ctx" = run ] || { echo "✗ --env is supported only on 'vm run' (vm up is an interactive login)" >&2; return 2; }
                  case "$1" in
                    --env=*) env_prefix+=$(_env_export "''${1#--env=}") || return 2; shift ;;
                    *)       env_prefix+=$(_env_export "''${2:?'--env needs KEY=VALUE'}") || return 2; shift 2 ;;
                  esac ;;
                --)         shift; break ;;
                -*)         echo "✗ unknown option: $1" >&2; return 2 ;;
                *)          break ;;
              esac
            done
            PARSE_REST=("$@")
          }

          # Resolve the launch grant. $1 mode(trusted|isolated|set|default) $2 csv(for set) $3 vm-default csv.
          # Echoes the normalized space-separated grant; exits 2 on an unknown token in a --trust csv.
          _resolve_grant() {
            local mode=$1 csv=$2 def=$3 out="" t
            case "$mode" in
              trusted)  out="$VALID_TRUST_TOKENS" ;;
              isolated) out="" ;;
              set)
                for t in ''${csv//,/ }; do
                  _in_list "$t" $VALID_TRUST_TOKENS || {
                    echo "✗ unknown trust token: '$t' (valid: ''${VALID_TRUST_TOKENS// /, })" >&2; return 2; }
                  _in_list "$t" $out || out="''${out:+$out }$t"
                done ;;
              default)  out="''${def//,/ }" ;;
            esac
            printf '%s' "$out"
          }

          usage() {
            cat <<'EOF'
          Usage: nix-vm <command> [name]  (alias: vm)

          Commands:
            build <name>          Build VM guest image (run before first up, or after rebuild)
            up    [opts] <name>          Start VM interactively (attaches serial console)
            run   [opts] <name> <cmd…>   Boot headlessly, run a command, stream output, return exit code
            attach <id|name> [cmd…]      Open a shell in a running box by its sandy id (multi-attach)

          Launch options (before <name>; isolated by default — nothing granted unless asked):
            --trusted             Grant every capability this VM declares (secrets + agent + shares)
            --isolated            Grant nothing (overrides the VM's default trust)
            --trust <a,b>         Grant an explicit set (tokens: secrets, agent, shares)
            --env KEY=VALUE       Export KEY into the command's env (run only; repeatable)
            --mount <hostdir>     Share <hostdir> into the guest for this launch (RW; overrides defaultMount)
            --cpu N               Override the guest vCPU count for this launch
            --mem MiB             Override the guest memory (MiB) for this launch
            --tun-passthrough     Route the guest into the host's current Tailscale mesh (vfkit only):
                                  reach tailnet servers via the host's authenticated tunnel
            test  <name> [secs]   Headless smoke-test: boot to multi-user then tear down (exit 0=pass)
            down  <name>          Stop the shared SSH-agent bridge for a VM
            list                  Show defined VMs, bridge status, and running sandboxes (with ids)
            doctor [--watch [s]] [name…]
                                  Verify + self-heal the SSH-agent bridge of running VM(s)
            builder <cmd>         Manage the vfkit linux-builder (macOS): up|down|status|logs
          EOF
            echo ""
            echo "Defined VMs: $DEFINED_VMS"
          }

          # Generate a random locally-administered unicast MAC (02:xx:xx:xx:xx:xx).
          _rand_mac() {
            printf '02:%s' "$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n' | fold -w2 | paste -sd:)"
          }

          # Host side of the vfkit usermode-NAT gateway = the vmnet bridge interface's inet address
          # (which is the guest's default gateway). It varies by vfkit/vmnet version — 192.168.64.1
          # on vfkit 0.6.x, 192.168.65.1 on earlier ones — so detect it instead of hardcoding.
          # Prints the address, or fails (empty) until the bridge exists (cold start). Darwin only.
          _vfkit_gateway() {
            local b ip
            for b in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^bridge[0-9]+$'); do
              ip=$(ifconfig "$b" 2>/dev/null | awk '/inet 192\.168\./{print $2; exit}')
              [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
            done
            return 1
          }

          # Ensure exactly one SSH-agent relay is running for a VM (shared across concurrent instances).
          # Pidfile lives in the base dir so the per-instance cleanup trap never kills it.
          _ensure_agent_bridge() {
            local name=''${1:?} base_dir=''${2:?}
            local port="''${VM_VSOCK_PORTS[$name]:?'Unknown VM: use vm list'}"
            [ "''${VM_FORWARD_AGENT[$name]:-1}" = 1 ] || return 0
            # Launch-time trust: bridge the host agent only when `agent` is granted this launch.
            # ($GRANT is the launch grant; vm_doctor sets it from the persisted per-VM .launch-grant.)
            _in_list agent "$GRANT" || { echo "→ SSH agent withheld from $name (not trusted this launch)"; return 0; }
            if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
              echo "⚠  SSH_AUTH_SOCK not set — agent forwarding disabled"
              return 0
            fi
            local pid_file="$base_dir/agent-bridge.pid"
            local target_file="$base_dir/agent-bridge.target"
            local lock_dir="$base_dir/agent-bridge.lock"
            # Atomic mkdir critical section — prevents a start race when many instances launch at once.
            if mkdir "$lock_dir" 2>/dev/null; then
              trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' RETURN
              # A live relay is reusable only if it still bridges the CURRENT $SSH_AUTH_SOCK. The
              # macOS launchd agent socket rotates across login sessions, so a relay from an earlier
              # session keeps holding the port while dialing a vanished socket — replace it.
              local action; action=$(_agent_bridge_decide "$pid_file" "$target_file" "$SSH_AUTH_SOCK")
              if [ "$action" = reuse ]; then
                echo "→ SSH-agent bridge already running (pid $(cat "$pid_file"))"
              else
                if [ "$action" = restart ]; then
                  # Tear down the stale relay: socat child first (while its retry loop still lives,
                  # so it can't respawn), then the loop itself.
                  local old; old=$(cat "$pid_file" 2>/dev/null || true)
                  if [ -n "$old" ]; then
                    pkill -P "$old" 2>/dev/null || true
                    kill "$old" 2>/dev/null || true
                  fi
                  echo "→ SSH-agent bridge target changed — restarting (was pid ''${old:-?})"
                fi
                if [ "$OS" = "Darwin" ]; then
                  # vfkit user-mode NAT: TCP relay bound to the detected vmnet bridge gateway (VSOCK
                  # broken in 0.6.x). The gateway/interface only exists once a guest is running, so
                  # _vfkit_gateway is empty at cold start; run socat in a background retry loop that
                  # binds as soon as the bridge appears and re-establishes if the relay later drops
                  # (e.g. host sleep/wake). `fork` serves concurrent guests on the port.
                  ( while :; do
                      gw=$(_vfkit_gateway) || { sleep 2; continue; }
                      socat TCP-LISTEN:"$port",fork,bind="$gw",reuseaddr \
                            UNIX-CONNECT:"$SSH_AUTH_SOCK" 2>/dev/null
                      sleep 2
                    done ) &
                else
                  socat VSOCK-LISTEN:"$port",reuseaddr,fork \
                        UNIX-CONNECT:"$SSH_AUTH_SOCK" &
                fi
                echo $! > "$pid_file"
                printf '%s' "$SSH_AUTH_SOCK" > "$target_file"
                echo "→ SSH-agent bridge started (pid $!)"
              fi
            else
              # Another process holds the lock — wait briefly for it to finish
              local tries=0
              while [ -d "$lock_dir" ] && [ "$tries" -lt 20 ]; do
                sleep 0.2; tries=$((tries+1))
              done
              echo "→ SSH-agent bridge: pid $(cat "$pid_file" 2>/dev/null || echo '?')"
            fi
          }

          # Ensure the single shared host tunnel sshd (Darwin/vfkit only): a forward-only sshd bound to
          # the detected vmnet gateway (_vfkit_gateway):$SANDY_TSSHPORT, authorizing exactly the keys
          # the forwarded agent holds. Each guest dials it and requests `-R <rvport>:localhost:22`; `vm attach`
          # connects to 127.0.0.1:<rvport>. One per host, started idempotently; a retry loop rebinds
          # when the gateway interface (re)appears, mirroring the agent bridge. Gated on the `agent`
          # grant (the tunnel needs the forwarded agent) so `--isolated` launches opt out.
          _ensure_tunnel_sshd() {
            [ "$OS" = "Darwin" ] || return 0
            _in_list agent "$GRANT" || return 0
            local dir="$HOME/.local/state/microvm/tunnel"
            mkdir -p "$dir"; chmod 700 "$dir"
            # Refresh authorized_keys from the live agent each launch (keys may have been added since).
            if ! $SANDY_SSHADD -L > "$dir/authorized_keys" 2>/dev/null || [ ! -s "$dir/authorized_keys" ]; then
              echo "⚠  sandy: agent holds no keys (ssh-add -L empty) — attach tunnel not started" >&2
              return 0
            fi
            chmod 600 "$dir/authorized_keys"
            [ -f "$dir/hostkey" ] || $SANDY_SSHKEYGEN -q -t ed25519 -N "" -f "$dir/hostkey"
            # Forward-only sshd config (printf, not a heredoc: a col-0 heredoc terminator would break
            # the surrounding indented-string formatting). Leading whitespace is tolerated by sshd.
            printf '%s\n' \
              "Port $SANDY_TSSHPORT" \
              "HostKey $dir/hostkey" \
              "AuthorizedKeysFile $dir/authorized_keys" \
              "PidFile none" \
              "StrictModes no" \
              "PasswordAuthentication no" \
              "KbdInteractiveAuthentication no" \
              "AllowTcpForwarding remote" \
              "GatewayPorts no" \
              "PermitTTY no" \
              "X11Forwarding no" \
              "AllowAgentForwarding no" \
              "PrintMotd no" \
              "PermitRootLogin no" \
              > "$dir/sshd_config"
            local loop_pid="$dir/loop.pid" lock_dir="$dir/sshd.lock"
            if mkdir "$lock_dir" 2>/dev/null; then
              trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' RETURN
              if [ -f "$loop_pid" ] && kill -0 "$(cat "$loop_pid" 2>/dev/null)" 2>/dev/null; then
                : # already running — one shared sshd serves every box
              else
                # The vmnet bridge gateway only exists once a guest is up and its address varies by
                # host/vfkit version, so detect it each iteration (exactly like the agent bridge) and
                # bind it via -o. sshd -D foregrounds; the loop rebinds if the address is not yet/no
                # longer present. ListenAddress is intentionally NOT in the config file.
                ( while :; do
                    gw=$(_vfkit_gateway) || { sleep 2; continue; }
                    $SANDY_SSHD -D -o "ListenAddress=$gw" -f "$dir/sshd_config" 2>>"$dir/sshd.err"
                    sleep 2
                  done ) &
                echo $! > "$loop_pid"
                echo "→ sandy tunnel sshd started (port $SANDY_TSSHPORT)"
              fi
            fi
          }

          # Prepare a VM instance: create the per-instance working dir, install the cleanup trap,
          # start the shared SSH-agent bridge, run the consumer hostPreLaunch hook, and copy+patch
          # the runner script with a per-instance random MAC (ephemeral VMs only).
          # Sets globals INST_DIR (working dir) and RUNNER (executable to launch).
          _vm_prepare() {
            local name=''${1:?}
            local base_dir="$HOME/.local/state/microvm/$name"
            local persistent="''${VM_PERSISTENT[$name]:-0}"

            if [ "$persistent" = 1 ]; then
              # Persistent: fixed base dir; home.img/store.img survive. Single-instance only.
              INST_DIR="$base_dir"
              mkdir -p "$INST_DIR"
              if [ -f "$INST_DIR/instance.lock" ] && kill -0 "$(cat "$INST_DIR/instance.lock" 2>/dev/null)" 2>/dev/null; then
                echo "✗ '$name' is persistent and already running (pid $(cat "$INST_DIR/instance.lock")). Not starting a second instance." >&2
                return 1
              fi
            else
              # Ephemeral: per-instance working dir. The guest's volume/socket paths are RELATIVE,
              # so each launch runs from its own dir → concurrent instances, wiped on exit.
              INST_DIR="$base_dir/run.$$.$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
              mkdir -p "$INST_DIR"
            fi

            cd "$INST_DIR" || { echo "cannot enter $INST_DIR" >&2; return 1; }
            [ "$persistent" = 1 ] && echo $$ > "$INST_DIR/instance.lock"

            # Assign this launch a unique sandy identity (five-word name + 8-hex short id), avoiding a
            # collision with any live box. Exposed as globals BOX_NAME/BOX_SHORTID for vm_up/vm_run.
            BOX_SHORTID=$(_sandy_gen_shortid)
            while [ -e "$(_sandy_boxes_dir)/$BOX_SHORTID.json" ]; do BOX_SHORTID=$(_sandy_gen_shortid); done
            BOX_NAME=$(_sandy_gen_name)
            while _sandy_resolve "$BOX_NAME" >/dev/null 2>&1; do BOX_NAME=$(_sandy_gen_name); done
            local box_file; box_file="$(_sandy_boxes_dir)/$BOX_SHORTID.json"

            # Cleanup trap: on real teardown, drop this instance's helper pids + transient files +
            # the sandy record, and wipe the dir if ephemeral. Guarded inside _sandy_reap_box so a
            # stray INT/TERM to the launcher while the guest is still running is a NO-OP — it must
            # not orphan a live box (delete its record) or rm -rf a live guest's /home. Values baked
            # in so the trap stays valid after _vm_prepare returns.
            trap '_sandy_reap_box "'"$box_file"'" "'"$INST_DIR"'" "'"$persistent"'"' EXIT INT TERM

            mkdir -p "$base_dir"
            # Persist this launch's grant so `vm doctor` can honour the same agent trust when it
            # later repairs the (per-VM, shared) bridge. Reflects the most recent launch of the VM.
            printf '%s' "$GRANT" > "$base_dir/.launch-grant"
            _ensure_agent_bridge "$name" "$base_dir"
            _ensure_tunnel_sshd  # shared host sshd for `vm attach` reverse tunnels (Darwin/vfkit)

            # Consumer host hook (credential staging, etc.); runs with CWD = INST_DIR and $name set.
            case "$name" in
            ${hostPreLaunchDispatch}
            esac

            # Build (or use cached) runner, copy to instance dir to make it writable for patching.
            local runner_pkg
            runner_pkg=$(nix build --no-link --print-out-paths "$FLAKE#microvm-$name")
            cp -L "$runner_pkg/bin/microvm-run" "$INST_DIR/microvm-run"
            chmod u+wx "$INST_DIR/microvm-run"  # cp -L preserves nix store 0500; need +w to allow mv to overwrite

            # Assemble every per-launch runner edit, then apply them in a single rewrite (see
            # _patch_runner). Each knob is a baked literal in the runner:
            #   MAC       ephemeral only → distinct NAT lease → safe concurrent boot. The guest matches
            #             its NIC by interface name (networkd Name=en*/eth*), not MAC, so this is safe.
            #   mount     point the launchmount share's source at --mount/defaultMount (empty otherwise).
            #   cpu/mem   engine-specific (vfkit --cpus/--memory; qemu -smp/-m<N>M).
            local -a edits=()
            # Determine this instance's NIC MAC and derive its reverse-tunnel port from it — host and
            # guest derive the SAME rvport from the SAME MAC (see sandy-lib.sh / guest.nix). Ephemeral
            # instances get a fresh MAC; bump it until the derived rvport is free among live boxes.
            local mac rvport
            if [ "$persistent" != 1 ]; then
              mac=$(_rand_mac); rvport=$(_sandy_rvport_for_mac "$mac")
              while _sandy_rvport_in_use "$rvport" "$box_file"; do
                mac=$(_rand_mac); rvport=$(_sandy_rvport_for_mac "$mac")
              done
              edits+=(-e "s|mac=([0-9a-f]{2}:){5}[0-9a-f]{2}|mac=$mac|")
            else
              mac=$(grep -oE 'mac=([0-9a-f]{2}:){5}[0-9a-f]{2}' "$INST_DIR/microvm-run" | head -1 | sed 's/^mac=//')
              rvport=$(_sandy_rvport_for_mac "$mac")
            fi

            # Register the box with sandy now that its rvport is known, so `vm list`/`vm attach` see it.
            # The cleanup trap removes the record on every exit path; `vm list` prunes dead records.
            local _hv _created _sess
            [ "$OS" = "Darwin" ] && _hv=vfkit || _hv=qemu
            _created=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
            _sess="''${TERM_SESSION_ID:-$(tty 2>/dev/null || echo '?')}:$$"
            _sandy_write_box "$BOX_SHORTID" "$BOX_NAME" "$name" "$INST_DIR" "$$" "$_hv" "$rvport" "$_created" "$_sess"

            if [ "''${VM_LAUNCH_MOUNT[$name]:-0}" = 1 ]; then
              mkdir -p "$INST_DIR/mount" # relative share source; empty dir = isolated default
              [ -n "$MOUNT_SRC" ] && {
                edits+=(-e "s|sharedDir=mount,mountTag=launchmount|sharedDir=$MOUNT_SRC,mountTag=launchmount|")
                echo "→ mounting $MOUNT_SRC in $name"
              }
            elif [ -n "$MOUNT_SRC" ]; then
              echo "✗ --mount: '$name' was built without a launch-mount slot (launchMount = false)" >&2
              return 2
            fi

            # cpu/mem: compute the sed clause and the verify pattern together, per engine.
            local cpu_pat="" mem_pat=""
            if [ "$OS" = "Darwin" ]; then
              [ -n "$CPU_OVERRIDE" ] && { cpu_pat="--cpus $CPU_OVERRIDE";   edits+=(-e "s/--cpus [0-9][0-9]*/$cpu_pat/"); }
              [ -n "$MEM_OVERRIDE" ] && { mem_pat="--memory $MEM_OVERRIDE"; edits+=(-e "s/--memory [0-9][0-9]*/$mem_pat/"); }
            else
              [ -n "$CPU_OVERRIDE" ] && { cpu_pat="-smp $CPU_OVERRIDE";       edits+=(-e "s/-smp [0-9][0-9]*/$cpu_pat/"); }
              [ -n "$MEM_OVERRIDE" ] && { mem_pat="-m ''${MEM_OVERRIDE}M";    edits+=(-e "s/-m [0-9][0-9]*M/$mem_pat/"); }
            fi

            # --tun-passthrough: let the guest reach the host tailnet's servers. Tailnet peer IPs
            # (100.64.0.0/10) already work via gvproxy; the host's advertised RFC1918 subnet routes need
            # an explicit guest route. Enumerate them from the host tailscale and inject them on the
            # kernel cmdline; the guest's sandy-tunpass unit adds `ip route … via <gw>` for each. No NAT
            # or host config needed — proven live. Whatever mesh the host is logged into is reached.
            if [ "$TUN_PASSTHROUGH" = 1 ]; then
              if [ "$OS" != "Darwin" ]; then
                echo "⚠  --tun-passthrough is vfkit/macOS-only — ignoring" >&2
              else
                local _tsr; _tsr=$(_tailscale_routes)
                [ -n "$_tsr" ] || echo "⚠  --tun-passthrough: host tailscale carries no subnet routes — is it up and logged in with a subnet-router peer online? (tailnet peer IPs still reachable)" >&2
                local _routes="100.64.0.0/10''${_tsr:+,$_tsr}"
                edits+=(-e "s| init=| sandy.tunpass=1 sandy.tunroutes=$_routes init=|")
                echo "→ tun-passthrough: guest will route → $_routes (via host tailnet)"
              fi
            fi

            [ ''${#edits[@]} -gt 0 ] && _patch_runner "''${edits[@]}"

            # Verify the cpu/mem overrides actually landed — a runner-format drift must surface, not
            # silently boot the built-in size. (MAC/mount edits are not verified: pre-existing behavior.)
            [ -n "$cpu_pat" ] && { grep -q -- "$cpu_pat" "$INST_DIR/microvm-run" && echo "→ cpu override: $CPU_OVERRIDE" \
              || echo "⚠  --cpu override did not match the runner — booting with the built-in vcpu" >&2; }
            [ -n "$mem_pat" ] && { grep -q -- "$mem_pat" "$INST_DIR/microvm-run" && echo "→ mem override: ''${MEM_OVERRIDE} MiB" \
              || echo "⚠  --mem override did not match the runner — booting with the built-in mem" >&2; }

            RUNNER="$INST_DIR/microvm-run"
          }

          vm_up() {
            # A PTY re-exec (below) carries the already-resolved grant + mount + cpu/mem via env;
            # skip re-parsing then, otherwise parse the shared launch options (--env rejected on up).
            if [ "''${VM_GRANT_OVERRIDE_SET:-}" = 1 ]; then
              GRANT="''${VM_GRANT_OVERRIDE:-}"
              MOUNT_SRC="''${VM_MOUNT_OVERRIDE:-}"
              CPU_OVERRIDE="''${VM_CPU_OVERRIDE:-}"
              MEM_OVERRIDE="''${VM_MEM_OVERRIDE:-}"
              TUN_PASSTHROUGH="''${VM_TUN_PASSTHROUGH:-0}"
            else
              _parse_launch_opts up "$@" || return 2
              set -- "''${PARSE_REST[@]}"
            fi
            local name=''${1:?'Usage: vm up [trust] [--mount DIR] [--cpu N] [--mem MiB] <name>'}
            if [ "''${VM_GRANT_OVERRIDE_SET:-}" != 1 ]; then
              GRANT=$(_resolve_grant "$mode" "$csv" "''${VM_TRUST_DEFAULT[$name]:-}") || return 2
              _resolve_default_mount "$name"
            fi
            [ "''${VM_DEBUG_GRANT:-}" = 1 ] && { _debug_grant; return 0; }
            # vfkit's virtio-serial,stdio requires a real TTY. Re-exec through a PTY when stdin is not one.
            if [ "$OS" = "Darwin" ] && ! [ -t 0 ]; then
              command -v python3 >/dev/null 2>&1 \
                || { echo "✗ vm up needs python3 to allocate a PTY (vfkit requires a TTY for the serial console)" >&2; return 2; }
              exec env VM_GRANT_OVERRIDE="$GRANT" VM_GRANT_OVERRIDE_SET=1 VM_MOUNT_OVERRIDE="$MOUNT_SRC" \
                VM_CPU_OVERRIDE="$CPU_OVERRIDE" VM_MEM_OVERRIDE="$MEM_OVERRIDE" VM_TUN_PASSTHROUGH="$TUN_PASSTHROUGH" \
                python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' "$0" up "$name"
            fi
            _vm_prepare "$name" || return ''${?}
            if [ "''${VM_PERSISTENT[$name]:-0}" = 1 ]; then
              echo "→ Launching persistent VM '$name'… (poweroff inside to stop)"
            else
              echo "→ Launching VM '$name' (instance ''${INST_DIR##*/})… (poweroff inside to stop)"
            fi
            echo "   sandy id: $BOX_NAME  ($BOX_SHORTID)  —  attach elsewhere: vm attach $BOX_SHORTID"
            "$RUNNER"
          }

          vm_run() {
            _parse_launch_opts run "$@" || return 2
            set -- "''${PARSE_REST[@]}"
            local name=''${1:?'Usage: vm run [trust] [--env K=V]… [--mount DIR] [--cpu N] [--mem MiB] <name> <command…>'}
            shift
            local cmd="$*"
            GRANT=$(_resolve_grant "$mode" "$csv" "''${VM_TRUST_DEFAULT[$name]:-}") || return 2
            _resolve_default_mount "$name"
            [ "''${VM_DEBUG_GRANT:-}" = 1 ] && { _debug_grant "$env_prefix"; return 0; }
            [ -n "$cmd" ] || { echo "✗ vm run: command required" >&2; return 2; }
            command -v python3 >/dev/null 2>&1 || { echo "✗ vm run needs python3 (console driver)" >&2; return 2; }
            _vm_prepare "$name" || return ''${?}
            # Prepend --env exports so they are set for the command's shell (and its children).
            cmd="$env_prefix$cmd"
            # Base64-encode the command to avoid all quoting hazards on the serial console
            local b64cmd
            b64cmd=$(printf '%s' "$cmd" | base64 | tr -d '\n')
            echo "→ Running in '$name' (instance ''${INST_DIR##*/})…"
            echo "   sandy id: $BOX_NAME  ($BOX_SHORTID)"
            python3 ${./vm-console-run.py} "$RUNNER" "$b64cmd"
          }

          # Attach a shell to an already-running box over its reverse tunnel (Darwin/vfkit). Read-only:
          # never calls _vm_prepare, so it cannot start a second instance or touch instance.lock. With
          # a trailing command it runs that non-interactively; without one it opens an interactive shell.
          # Multi-attach is native — several `vm attach` sessions can share one running box.
          vm_attach() {
            local key=''${1:?'Usage: vm attach <id|name> [command…]'}; shift
            _sandy_prune
            local box; box=$(_sandy_resolve "$key") \
              || { echo "✗ no running box matches '$key' (see: vm list)" >&2; return 1; }
            local rv hv vm idn
            rv=$(_sandy_field "$box" rvport); hv=$(_sandy_field "$box" hypervisor)
            vm=$(_sandy_field "$box" vm_name); idn=$(_sandy_field "$box" id_name)
            if [ "$hv" != vfkit ] || [ -z "$rv" ]; then
              echo "✗ attach unavailable for '$idn' (vm=$vm, hypervisor=$hv)" >&2; return 2
            fi
            echo "→ attaching to '$idn' (vm=$vm) via 127.0.0.1:$rv …" >&2
            exec $SANDY_SSH -p "$rv" \
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
              "$USER@127.0.0.1" "$@"
          }

          vm_build() {
            local name=''${1:?'Usage: vm build <name>'}
            local gcroot_dir="$HOME/.local/state/microvm/gcroots"
            echo "→ Building VM '$name'…"
            mkdir -p "$gcroot_dir"
            # --out-link registers a GC root: the guest closure survives `nix-collect-garbage`,
            # so a later `vm up`/`vm run` reuses it instead of rebuilding via the linux-builder.
            nix build "$FLAKE#microvm-$name" --out-link "$gcroot_dir/microvm-$name"
            echo "✓ Done (pinned $gcroot_dir/microvm-$name — survives nix GC)"
          }

          # Scripted boot smoke-test: build+boot the VM headlessly and assert it reaches multi-user,
          # then tear it down. Exit 0 = pass. vfkit's serial console needs a TTY, so we drive `vm up`
          # through a pseudo-terminal. Requires the linux-builder for a fresh guest build.
          vm_test() {
            local name="''${1:?Usage: vm test <name> [timeout_s]}"
            local timeout="''${2:-360}"
            command -v python3 >/dev/null 2>&1 || { echo "✗ vm test needs python3 (for a PTY console)" >&2; return 2; }
            local log; log=$(mktemp -t "vm-test-$name.XXXXXX")
            echo "→ Smoke-testing '$name' (timeout ''${timeout}s)…  log: $log"
            python3 -c 'import pty,sys; pty.spawn([sys.argv[1],"up",sys.argv[2]])' "$0" "$name" >"$log" 2>&1 &
            local boot_pid=$! rc=2 waited=0
            while kill -0 "$boot_pid" 2>/dev/null; do
              if grep -qaE "Reached target .*Multi-User|$name login:" "$log"; then rc=0; break; fi
              if grep -qaiE 'operation not supported by device|Emergency Mode|Dependency failed for|Timed out waiting for device|Kernel panic|cannot build|build of .* failed' "$log"; then rc=1; break; fi
              [ "$waited" -ge "$timeout" ] && { rc=3; break; }
              sleep 3; waited=$((waited+3))
            done
            # Tear down: SIGTERM vfkit → nix run returns → vm_up's trap wipes the instance dir.
            pkill -TERM -f "microvm@$name" 2>/dev/null || true
            sleep 2; kill "$boot_pid" 2>/dev/null || true
            case "$rc" in
              0) echo "✓ PASS: '$name' reached multi-user in ''${waited}s"; rm -f "$log" ;;
              1) echo "✗ FAIL: '$name' boot error (log: $log):"; grep -aiE 'not supported|Emergency|Dependency failed|Timed out|panic|cannot build|failed' "$log" | tail -3 | sed 's/^/    /' ;;
              3) echo "✗ FAIL: '$name' timed out after ''${timeout}s (log: $log)" ;;
              *) echo "✗ FAIL: '$name' exited before boot (log: $log):"; tail -3 "$log" | sed 's/^/    /' ;;
            esac
            return "$rc"
          }

          vm_down() {
            local name=''${1:?'Usage: vm down <name>'}
            local base_dir="$HOME/.local/state/microvm/$name"
            local pid_file="$base_dir/agent-bridge.pid"
            if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
              local bpid; bpid=$(cat "$pid_file")
              # Kill the socat child first (while its parent — the retry loop — is still alive, so
              # it can't be respawned), then the loop itself. Otherwise socat orphans and lingers.
              pkill -P "$bpid" 2>/dev/null || true
              kill "$bpid" 2>/dev/null || true
              rm -f "$pid_file"
              echo "→ Agent bridge for '$name' stopped"
            else
              echo "No running bridge for '$name'"
            fi
          }

          vm_list() {
            echo "Defined microVMs:"
            for name in $DEFINED_VMS; do
              local base_dir="$HOME/.local/state/microvm/$name"
              if [ -f "$base_dir/agent-bridge.pid" ] && \
                 kill -0 "$(cat "$base_dir/agent-bridge.pid" 2>/dev/null)" 2>/dev/null; then
                echo "  $name  [bridge running]"
              else
                echo "  $name  [stopped]"
              fi
            done

            _sandy_prune
            echo "Running sandboxes:"
            local _any=0 _bf
            for _bf in "$(_sandy_boxes_dir)"/*.json; do
              [ -e "$_bf" ] || continue
              _any=1
              printf '  %s  (%s)  vm=%s  pid=%s\n' \
                "$(_sandy_field "$_bf" id_name)" "$(_sandy_field "$_bf" short_id)" \
                "$(_sandy_field "$_bf" vm_name)" "$(_sandy_field "$_bf" pid)"
            done
            [ "$_any" = 1 ] || echo "  (none)"
          }

          # Is a runner process live for this VM? (matches the per-instance/base dir in the cmdline)
          _vm_running() { pgrep -f "microvm/$1/" >/dev/null 2>&1; }

          # Is the SSH-agent relay actually LISTENING? A live pidfile is not proof — on host
          # sleep/wake the vmnet gateway churns and socat's bound socket dies under the process.
          # Darwin = TCP relay on the vfkit NAT gateway; qemu/vsock has no cheap probe (assume ok).
          _bridge_bound() {
            [ "$OS" = "Darwin" ] || return 0
            local gw; gw=$(_vfkit_gateway) || return 1
            lsof -nP -iTCP@"$gw":"$1" -sTCP:LISTEN >/dev/null 2>&1
          }

          # Verify — and self-heal — the SSH-agent bridge of running VM(s). The bridge is a bare
          # socat bound to the ephemeral vmnet gateway; a host sleep/wake cycle kills it with no
          # restart, leaving a running VM unable to reach the host agent (git/ssh fail inside).
          # This repairs it WITHOUT touching vfkit, so an ephemeral VM's /home is never wiped.
          #   vm doctor                one-shot, all running VMs
          #   vm doctor <name…>        one-shot, specific VMs
          #   vm doctor --watch [sec]  keep verifying every <sec> (default 30) — cheap supervisor
          vm_doctor() {
            local watch=0 interval=30
            if [ "''${1:-}" = --watch ]; then
              watch=1; shift
              if [ -n "''${1:-}" ] && printf '%s' "''${1}" | grep -qE '^[0-9]+$'; then interval=''${1}; shift; fi
            fi
            local targets="$*"; [ -n "$targets" ] || targets="$DEFINED_VMS"
            while :; do
              for name in $targets; do
                local port="''${VM_VSOCK_PORTS[$name]:-}"
                if [ -z "$port" ]; then echo "· $name: agent forwarding off — skip"; continue; fi
                if ! _vm_running "$name"; then echo "· $name: not running — skip"; continue; fi
                local base_dir="$HOME/.local/state/microvm/$name"
                # Honour the launch grant: never resurrect a bridge for a VM launched without `agent`.
                GRANT=$(cat "$base_dir/.launch-grant" 2>/dev/null || echo "")
                if ! _in_list agent "$GRANT"; then echo "· $name: SSH agent withheld at launch — skip"; continue; fi
                local gw; gw=$(_vfkit_gateway 2>/dev/null || echo '?')
                if _bridge_bound "$port" && _agent_bridge_target_alive "$base_dir/agent-bridge.target"; then
                  echo "✓ $name: bridge healthy ($gw:$port)"
                else
                  echo "→ $name: running but bridge down or stale ($gw:$port) — repairing…"
                  rm -f "$base_dir/agent-bridge.pid" "$base_dir/agent-bridge.target"
                  rmdir "$base_dir/agent-bridge.lock" 2>/dev/null || true
                  _ensure_agent_bridge "$name" "$base_dir"
                fi
              done
              [ "$watch" = 1 ] || break
              sleep "$interval"
            done
          }

          case "''${1:-}" in
            build) vm_build "''${2:?'Usage: vm build <name>'}"; ;;
            up)    shift; vm_up  "$@"; ;;
            run)   shift; vm_run "$@"; ;;
            attach) shift; vm_attach "$@"; ;;
            test)  vm_test "''${2:?'Usage: vm test <name> [timeout_s]'}" "''${3:-}"; ;;
            down)  vm_down "''${2:?'Usage: vm down <name>'}"; ;;
            list)  vm_list; ;;
            doctor) shift; vm_doctor "$@"; ;;
            builder)
              shift
              command -v nix-vm-builder >/dev/null 2>&1 \
                || { echo "✗ 'vm builder' is macOS-only (the vfkit linux-builder)" >&2; exit 1; }
              exec nix-vm-builder "$@"
              ;;
            ""|--help|-h) usage; ;;
            *) echo "Unknown command: ''${1}"; echo; usage; exit 1; ;;
          esac
        '')
      ];
      home-manager.sharedModules = [ { home.shellAliases.vm = "nix-vm"; } ];
    }

    # ── macOS only ─────────────────────────────────────────────────────────────
    (mkIf pkgs.stdenv.isDarwin {
      # Register the vfkit linux-builder as a remote build machine.
      # Start it with: builder up
      nix.distributedBuilds = mkIf config.custom.nativeNix true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = mkIf config.custom.nativeNix [
        {
          hostName = "linux-builder";
          sshUser = "builder";
          sshKey = "/etc/nix/builder_ed25519";
          systems = [ "aarch64-linux" ];
          maxJobs = 4;
          supportedFeatures = [
            "benchmark"
            "big-parallel"
          ];
        }
      ];

      # SSH alias so the nix daemon (runs as root) reaches the vfkit builder.
      # linux-builder.local is published via Avahi mDNS by the builder VM.
      environment.etc."ssh/ssh_config.d/100-linux-builder.conf" = mkIf config.custom.nativeNix {
        text = ''
          Host linux-builder
            User builder
            Hostname linux-builder.local
            Port 22
            IdentityFile /etc/nix/builder_ed25519
            IdentitiesOnly yes
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
        '';
      };

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "nix-vm-builder" ''
                    set -euo pipefail
                    FLAKE="${flakeDir}"
                    STATE_DIR="$HOME/.local/state/microvm/linux-builder"
                    LOG="$STATE_DIR/console.log"
                    PID_FILE="$STATE_DIR/vm.pid"

                    # True when the vfkit runner is already built and present in the nix store.
                    runner_is_built() {
                      local path
                      path=$(nix eval --raw "$FLAKE#packages.aarch64-darwin.microvm-linux-builder.outPath" 2>/dev/null) || return 1
                      [ -e "$path" ]
                    }

                    # Bootstrap: builds the aarch64-linux derivations for the linux-builder inside an
                    # Apple Container (AVF-native aarch64-linux), exports them to a local binary cache,
                    # imports into the darwin nix store, then builds the darwin-side vfkit runner.
                    # Called automatically by cmd_up when the runner is not yet in the store.
                    do_bootstrap() {
                      if ! command -v container >/dev/null 2>&1; then
                        echo "✗ 'container' CLI not found — required for first-time bootstrap." >&2
                        echo "  Install: brew install --cask container" >&2
                        echo "  Then run 'builder up' (or 'nix-vm-builder up') again." >&2
                        exit 1
                      fi

                      local cache_dir
                      cache_dir=$(mktemp -d /tmp/nix-builder-bootstrap.XXXXXX)

                      echo "→ Ensuring Apple Container system is running..."
                      container system start 2>/dev/null || true

                      # Write the inner bootstrap script into the shared volume (avoids nesting hell).
                      cat > "$cache_dir/run.sh" << 'BOOTSTRAP'
          #!/bin/sh
          set -e
          # Wrapper so we don't have to repeat the --extra-experimental-features flag everywhere.
          nix_cmd() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

          echo "--> [1/3] Building NixOS system + EROFS store image..."
          # Build storeDisk (which depends on the NixOS system toplevel).
          # Use --no-link so nix doesn't try to create a result symlink.
          # Use nix path-info after the build to get the output path (avoids stdout-capture issues).
          nix_cmd build \
            /config#nixosConfigurations.linux-builder.config.microvm.storeDisk \
            --no-link
          DISK=$(nix_cmd path-info /config#nixosConfigurations.linux-builder.config.microvm.storeDisk)
          [ -z "$DISK" ] && { echo "ERROR: storeDisk path-info returned empty" >&2; exit 1; }

          echo "--> [2/3] Getting NixOS toplevel path..."
          TOPLEVEL=$(nix_cmd path-info \
            /config#nixosConfigurations.linux-builder.config.system.build.toplevel)
          [ -z "$TOPLEVEL" ] && { echo "ERROR: toplevel path-info returned empty" >&2; exit 1; }

          echo "--> [3/3] Exporting to binary cache..."
          # closure-info is a build-time dep of the vfkit runner (not a runtime dep of storeDisk),
          # so it won't be included in the transitive runtime closure export.  The storeDisk build
          # always builds closure-info as a prerequisite, so we grab all *-closure-info dirs that
          # exist in the store and export them alongside storeDisk + toplevel.
          CLOSURE_INFOS=$(find /nix/store -maxdepth 1 -type d -name '*-closure-info' 2>/dev/null | tr '\n' ' ')
          nix_cmd copy --to "file:///nix-out" "$TOPLEVEL" "$DISK" $CLOSURE_INFOS --no-check-sigs
          printf '%s\n' "$TOPLEVEL" > /nix-out/toplevel.txt
          printf '%s\n' "$DISK" > /nix-out/disk.txt
          find /nix/store -maxdepth 1 -type d -name '*-closure-info' > /nix-out/closure-infos.txt 2>/dev/null || true
          echo "--> Done."
          BOOTSTRAP

                      echo "→ Building aarch64-linux derivations inside Apple Container (AVF)..."
                      echo "   First run: ~5-10 min to download nixpkgs. Subsequent runs use cache."
                      # -m 8G: mkfs.erofs needs substantial RAM to pack the NixOS system closure.
                      container run --rm -m 8G \
                        -v "$FLAKE:/config:ro" \
                        -v "$cache_dir:/nix-out:rw" \
                        ghcr.io/nixos/nix:latest \
                        /bin/sh /nix-out/run.sh

                      local toplevel disk
                      toplevel=$(cat "$cache_dir/toplevel.txt")
                      disk=$(cat "$cache_dir/disk.txt")
                      # closure-info paths (may be multiple; space-separated for nix copy)
                      local closure_infos
                      closure_infos=$(cat "$cache_dir/closure-infos.txt" 2>/dev/null | tr '\n' ' ')

                      echo "→ Importing linux store paths into darwin nix store..."
                      # shellcheck disable=SC2086
                      nix copy --from "file://$cache_dir" "$toplevel" "$disk" $closure_infos --no-check-sigs

                      rm -rf "$cache_dir"

                      echo "→ Building vfkit runner (darwin-side only, fast)..."
                      # --out-link registers a GC root so `nix-collect-garbage` can't reclaim the
                      # runner and force a full re-bootstrap on the next `builder up`.
                      local gcroot_dir="$HOME/.local/state/microvm/gcroots"
                      mkdir -p "$gcroot_dir"
                      nix build "$FLAKE#packages.aarch64-darwin.microvm-linux-builder" \
                        --out-link "$gcroot_dir/microvm-linux-builder"

                      echo "✓ Bootstrap complete."
                    }

                    cmd_up() {
                      mkdir -p "$STATE_DIR"
                      if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                        echo "linux-builder already running (pid $(cat "$PID_FILE"))"
                        return
                      fi

                      # Auto-bootstrap: use Apple Container to build linux deps when not yet cached.
                      if ! runner_is_built; then
                        echo "→ linux-builder image not yet built — starting first-time bootstrap..."
                        do_bootstrap
                      fi

                      echo "→ Starting linux-builder (Apple Virtualization.framework)..."
                      # Run from STATE_DIR so microvm-run creates its relative-path files
                      # (builder-nix-store.img, linux-builder.sock, console-hvc0.log) there.
                      ( cd "$STATE_DIR" && nix run "$FLAKE#microvm-linux-builder" ) > "$LOG" 2>&1 &
                      echo $! > "$PID_FILE"
                      echo "→ Waiting for SSH on linux-builder.local (may take ~30 s on first boot)..."
                      local tries=0
                      until nc -z linux-builder.local 22 2>/dev/null; do
                        tries=$((tries+1))
                        [ "$tries" -ge 60 ] && { echo "✗ Timed out. Check logs: $LOG"; exit 1; }
                        sleep 2
                      done
                      echo "✓ linux-builder ready  (linux-builder.local:22)"
                    }

                    cmd_down() {
                      if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                        kill "$(cat "$PID_FILE")"
                        rm -f "$PID_FILE"
                        echo "→ linux-builder stopped"
                      else
                        echo "linux-builder is not running"
                      fi
                    }

                    cmd_status() {
                      if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                        echo "linux-builder: running (pid $(cat "$PID_FILE"))"
                        if nc -z linux-builder.local 22 2>/dev/null; then
                          echo "SSH:           reachable (linux-builder.local:22)"
                        else
                          echo "SSH:           not yet reachable (booting)"
                        fi
                      else
                        echo "linux-builder: stopped"
                        if runner_is_built; then
                          echo "Image:         built  (run 'builder up' (or 'nix-vm-builder up') to start)"
                        else
                          echo "Image:         not built  ('builder up' (or 'nix-vm-builder up') will auto-bootstrap via Apple Container)"
                        fi
                      fi
                    }

                    cmd_logs() { tail -f "$LOG"; }

                    case "''${1:-}" in
                      up)     cmd_up ;;
                      down)   cmd_down ;;
                      status) cmd_status ;;
                      logs)   cmd_logs ;;
                      *)
                        echo "Usage: vm builder <up|down|status|logs>   (alias: builder …)"
                        echo ""
                        echo "First run: 'vm builder up' bootstraps automatically via Apple Container when"
                        echo "the aarch64-linux image is not yet in the nix store (no QEMU required)."
                        ;;
                    esac
        '')
      ];
      home-manager.sharedModules = [ { home.shellAliases.builder = "nix-vm-builder"; } ];
    })

    # ── Linux only ─────────────────────────────────────────────────────────────
    (mkIf (!pkgs.stdenv.isDarwin) {
      users.users."${config.custom.username}".extraGroups = [ "kvm" ];
    })
  ]);
}
