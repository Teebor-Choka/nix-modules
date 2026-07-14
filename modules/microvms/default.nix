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

  vmNames = attrNames cfg;
  vmNamesStr = concatStringsSep " " vmNames;

  # Bake a bash assoc-array body ("[name]=v …") for the vm helper, one entry per VM.
  bakeMap = f: concatStringsSep " " (mapAttrsToList (name: spec: "[${name}]=${f spec}") cfg);

  # Bake vsock port mapping for the Linux vm helper (name → port; empty when agent forwarding off)
  vmPortsStr = bakeMap (spec: toString (spec.vsockPort or ""));
  # Whether the host `vm` helper should bridge the SSH agent for each VM (name → 0|1)
  vmForwardAgentStr = bakeMap (spec: if spec.forwardSshAgent then "1" else "0");
  vmPersistentStr = bakeMap (spec: if spec.persistent then "1" else "0");

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

  vmSubmodule = { name, ... }: {
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
        default = config.custom.username;
      };
      timeZone = mkOption {
        type = types.str;
        default = config.custom.microvmDefaults.timeZone;
      };
      locale = mkOption {
        type = types.str;
        default = config.custom.microvmDefaults.locale;
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
      forwardSshAgent = mkOption {
        type = types.bool;
        default = true;
        description = "Forward the host's SSH agent ($SSH_AUTH_SOCK) into the guest over virtio-vsock.";
      };
      vsockPort = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Unique virtio-vsock port for the forwarded SSH agent. Required when forwardSshAgent = true.";
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
    };
  };

  # Per-VM host launch hook dispatch (a shell `case` body). Runs the consumer-provided
  # hostPreLaunch shell for the VM being started. Multi-line, hence a case (not an assoc map).
  hostPreLaunchDispatch = concatStringsSep "\n" (
    mapAttrsToList (
      name: spec:
      optionalString (spec.hostPreLaunch != "") ''
              ${name})
        ${spec.hostPreLaunch}
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
      environment.systemPackages = [
        pkgs.socat

        (pkgs.writeShellScriptBin "nix-vm" ''
          set -euo pipefail

          FLAKE="${flakeDir}"
          DEFINED_VMS="${vmNamesStr}"
          OS=$(uname -s)

          # vsock port per VM name — baked in at Nix build time (Linux qemu bridge)
          declare -A VM_VSOCK_PORTS=(${vmPortsStr})

          # Per-VM persistence (0 = ephemeral per-instance, 1 = persistent single-instance)
          declare -A VM_PERSISTENT=(${vmPersistentStr})

          # Per-VM SSH-agent forwarding (1 = bridge the host agent, 0 = skip)
          declare -A VM_FORWARD_AGENT=(${vmForwardAgentStr})


          usage() {
            cat <<'EOF'
          Usage: nix-vm <command> [name]  (alias: vm)

          Commands:
            build <name>          Build VM guest image (run before first up, or after rebuild)
            up    <name>          Start VM interactively (attaches console, forwards SSH agent)
            run   <name> <cmd…>   Boot headlessly, run a command, stream output, return exit code
            test  <name> [secs]   Headless smoke-test: boot to multi-user then tear down (exit 0=pass)
            down  <name>          Stop the shared SSH-agent bridge for a VM
            list                  Show defined VMs and bridge status
          EOF
            echo ""
            echo "Defined VMs: $DEFINED_VMS"
          }

          # Generate a random locally-administered unicast MAC (02:xx:xx:xx:xx:xx).
          _rand_mac() {
            printf '02:%s' "$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n' | fold -w2 | paste -sd:)"
          }

          # Ensure exactly one SSH-agent relay is running for a VM (shared across concurrent instances).
          # Pidfile lives in the base dir so the per-instance cleanup trap never kills it.
          _ensure_agent_bridge() {
            local name=''${1:?} base_dir=''${2:?}
            local port="''${VM_VSOCK_PORTS[$name]:?'Unknown VM: use vm list'}"
            [ "''${VM_FORWARD_AGENT[$name]:-1}" = 1 ] || return 0
            if [ -z "''${SSH_AUTH_SOCK:-}" ]; then
              echo "⚠  SSH_AUTH_SOCK not set — agent forwarding disabled"
              return 0
            fi
            local pid_file="$base_dir/agent-bridge.pid"
            local lock_dir="$base_dir/agent-bridge.lock"
            # Atomic mkdir critical section — prevents a start race when many instances launch at once.
            if mkdir "$lock_dir" 2>/dev/null; then
              trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' RETURN
              if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
                echo "→ SSH-agent bridge already running (pid $(cat "$pid_file"))"
              else
                if [ "$OS" = "Darwin" ]; then
                  # vfkit user-mode NAT: host gateway 192.168.65.1; TCP relay (VSOCK broken in 0.6.x).
                  # The fork option handles multiple concurrent guests sharing the same port.
                  socat TCP-LISTEN:"$port",fork,bind=192.168.65.1,reuseaddr \
                        UNIX-CONNECT:"$SSH_AUTH_SOCK" &
                else
                  socat VSOCK-LISTEN:"$port",reuseaddr,fork \
                        UNIX-CONNECT:"$SSH_AUTH_SOCK" &
                fi
                echo $! > "$pid_file"
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

            # Cleanup trap: remove per-instance transient files; wipe the whole dir if ephemeral.
            # Bakes current values so the trap stays valid after _vm_prepare returns.
            trap '
              for pf in "'"$INST_DIR"'"/*.pid; do
                [ -e "$pf" ] || continue
                kill "$(cat "$pf")" 2>/dev/null || true
              done
              rm -f "'"$INST_DIR"'"/*.pid "'"$INST_DIR"'"/*.sock "'"$INST_DIR"'"/instance.lock
              [ "'"$persistent"'" = 1 ] || rm -rf "'"$INST_DIR"'"
            ' EXIT INT TERM

            mkdir -p "$base_dir"
            _ensure_agent_bridge "$name" "$base_dir"

            # Consumer host hook (credential staging, etc.); runs with CWD = INST_DIR and $name set.
            case "$name" in
            ${hostPreLaunchDispatch}
            esac

            # Build (or use cached) runner, copy to instance dir to make it writable for patching.
            local runner_pkg
            runner_pkg=$(nix build --no-link --print-out-paths "$FLAKE#microvm-$name")
            cp -L "$runner_pkg/bin/microvm-run" "$INST_DIR/microvm-run"
            chmod u+wx "$INST_DIR/microvm-run"  # cp -L preserves nix store 0500; need +w to allow mv to overwrite

            if [ "$persistent" != 1 ]; then
              # Give each ephemeral instance a distinct MAC → distinct NAT lease → safe concurrent boot.
              # The guest matches its NIC by interface name (networkd Name=en*/eth*), not by MAC address,
              # so patching the runner's mac= literal does not break guest networking.
              local new_mac
              new_mac=$(_rand_mac)
              sed -E "s|mac=([0-9a-f]{2}:){5}[0-9a-f]{2}|mac=$new_mac|" \
                  "$INST_DIR/microvm-run" > "$INST_DIR/.microvm-run.new"
              chmod u+x "$INST_DIR/.microvm-run.new"
              mv "$INST_DIR/.microvm-run.new" "$INST_DIR/microvm-run"
            fi

            RUNNER="$INST_DIR/microvm-run"
          }

          vm_up() {
            local name=''${1:?'Usage: vm up <name>'}
            # vfkit's virtio-serial,stdio requires a real TTY. Re-exec through a PTY when stdin is not one.
            if [ "$OS" = "Darwin" ] && ! [ -t 0 ]; then
              command -v python3 >/dev/null 2>&1 \
                || { echo "✗ vm up needs python3 to allocate a PTY (vfkit requires a TTY for the serial console)" >&2; return 2; }
              exec python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' "$0" up "$name"
            fi
            _vm_prepare "$name" || return ''${?}
            if [ "''${VM_PERSISTENT[$name]:-0}" = 1 ]; then
              echo "→ Launching persistent VM '$name'… (poweroff inside to stop)"
            else
              echo "→ Launching VM '$name' (instance ''${INST_DIR##*/})… (poweroff inside to stop)"
            fi
            "$RUNNER"
          }

          vm_run() {
            local name=''${1:?'Usage: vm run <name> <command…>'}
            shift
            local cmd="$*"
            [ -n "$cmd" ] || { echo "✗ vm run: command required" >&2; return 2; }
            command -v python3 >/dev/null 2>&1 || { echo "✗ vm run needs python3 (console driver)" >&2; return 2; }
            _vm_prepare "$name" || return ''${?}
            # Base64-encode the command to avoid all quoting hazards on the serial console
            local b64cmd
            b64cmd=$(printf '%s' "$cmd" | base64 | tr -d '\n')
            echo "→ Running in '$name' (instance ''${INST_DIR##*/})…"
            python3 ${./vm-console-run.py} "$RUNNER" "$b64cmd"
          }

          vm_build() {
            local name=''${1:?'Usage: vm build <name>'}
            echo "→ Building VM '$name'…"
            nix build "$FLAKE#microvm-$name"
            echo "✓ Done"
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
              kill "$(cat "$pid_file")"
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
          }

          case "''${1:-}" in
            build) vm_build "''${2:?'Usage: vm build <name>'}"; ;;
            up)    vm_up   "''${2:?'Usage: vm up <name>'}"; ;;
            run)   vm_run  "''${2:?'Usage: vm run <name> <command…>'}" "''${@:3}"; ;;
            test)  vm_test "''${2:?'Usage: vm test <name> [timeout_s]'}" "''${3:-}"; ;;
            down)  vm_down "''${2:?'Usage: vm down <name>'}"; ;;
            list)  vm_list; ;;
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
                      nix build "$FLAKE#packages.aarch64-darwin.microvm-linux-builder"

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
                        echo "Usage: builder <up|down|status|logs>"
                        echo ""
                        echo "First run: 'builder up' (or 'nix-vm-builder up') bootstraps automatically via Apple Container when"
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
