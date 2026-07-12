# modules/microvms/default.nix
# Host-side module (darwin or NixOS) — declares custom.microvms options,
# configures the linux-builder on darwin, and provides the `vm` helper.
{ config, pkgs, lib, ... }:
with lib;
let
  cfg      = config.custom.microvms;
  flakeDir = config.custom.flakeDir;

  vmNames    = attrNames cfg;
  vmNamesStr = concatStringsSep " " vmNames;

  # Bake vsock port mapping for the Linux vm helper (name → port)
  vmPortsStr = concatStringsSep " " (
    mapAttrsToList (name: spec: "[${name}]=${toString spec.vsockPort}") cfg
  );

  # Platform-derived home directory prefix for option defaults
  homePrefix = if pkgs.stdenv.isDarwin then "/Users" else "/home";

  # Stable, deterministic locally-administered MAC from the VM name
  nameMac = name:
    let
      h = builtins.hashString "sha256" name;
      o = i: substring (i * 2) 2 h;
    in "02:${o 1}:${o 2}:${o 3}:${o 4}:${o 5}";

  vmSubmodule = { name, ... }: {
    options = {
      hypervisor     = mkOption {
        type    = types.str;
        default = if pkgs.stdenv.isDarwin then "vfkit" else "qemu";
        description = "microvm.nix hypervisor backend (vfkit on macOS, qemu on Linux)";
      };
      vcpu           = mkOption { type = types.int;  default = 12; };
      mem            = mkOption { type = types.int;  default = 10240; };
      homeSize       = mkOption { type = types.int;  default = 10240; };
      storeSize      = mkOption { type = types.int;  default = 20480; };
      user           = mkOption { type = types.str;  default = config.custom.username; };
      timeZone       = mkOption { type = types.str;  default = config.custom.microvmDefaults.timeZone; };
      locale         = mkOption { type = types.str;  default = config.custom.microvmDefaults.locale; };
      autologin      = mkOption { type = types.bool; default = true; };
      mac            = mkOption {
        type    = types.str;
        default = nameMac name;
        description = "Guest NIC MAC address (auto-derived; override if needed)";
      };
      hmModules      = mkOption {
        type    = types.listOf types.path;
        default = [ ../../home-manager/home.nix ];
        description = ''
          Base home-manager modules imported into every guest (generic, user-agnostic).
          Defaults to the shared base (home-manager/home.nix).
          Per-user layers (scripts, dotfiles, git identity, etc.) are added via extraHmModules
          in the per-VM config (e.g. claude.nix).
        '';
      };
      extraHmModules = mkOption { type = types.listOf types.path; default = []; };
      sshConfig      = mkOption {
        type    = types.lines;
        default = "";
        description = "Extra ~/.ssh/config content (Host alias blocks for key selection)";
      };
      sshPubKeys     = mkOption {
        type        = types.attrsOf types.str;
        default     = {};
        description = "Public key files to place in ~/.ssh/ (filename → content)";
        example     = literalExpression ''{ "work.pub" = "ssh-ed25519 AAAA…"; }'';
      };
      vsockPort      = mkOption {
        type        = types.int;
        description = "Unique virtio-vsock port for KeePassXC agent forwarding";
      };
      extraShares    = mkOption {
        type = types.listOf (types.submodule {
          options = {
            source     = mkOption { type = types.str; description = "Absolute host path to share"; };
            mountPoint = mkOption { type = types.str; description = "Absolute guest mount path"; };
            tag        = mkOption {
              type    = types.str;
              default = "";
              description = "virtiofs tag (auto-derived from basename(mountPoint) when empty)";
            };
          };
        });
        default     = [];
        description = "Extra host directories to share into this VM (virtiofs, read-write). Opt-in per VM.";
        example     = literalExpression ''
          [{ source = "/Users/alice/Projects"; mountPoint = "/home/alice/Projects"; }]
        '';
      };
      vfkitExtraArgs = mkOption { type = types.listOf types.str; default = []; };
      extraModules   = mkOption { type = types.listOf types.unspecified; default = []; };

      # ── Non-persistent /home backing ──────────────────────────────────────────
      homeBacking = mkOption {
        type    = types.enum [ "tmpfs" "disk" "auto" ];
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
        type    = types.bool;
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
        type    = types.enum [ "host" "image" ];
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
        type    = types.lines;
        default = "";
        description = ''
          Shell executed on the host by the `vm` helper immediately before launching this VM.
          Use it to wire secret/mount mechanisms (e.g. a vsock credential agent) without this
          library knowing about them. Guest-side pieces go through extraModules.
        '';
      };
    };
  };

  # Baked per-VM persistence map for the vm helper (name → 0|1)
  vmPersistentStr = concatStringsSep " " (
    mapAttrsToList (name: spec: "[${name}]=${if spec.persistent then "1" else "0"}") cfg
  );

  # Per-VM host launch hook dispatch (a shell `case` body). Runs the consumer-provided
  # hostPreLaunch shell for the VM being started. Multi-line, hence a case (not an assoc map).
  hostPreLaunchDispatch = concatStringsSep "\n" (mapAttrsToList (name: spec:
    optionalString (spec.hostPreLaunch != "") ''
            ${name})
      ${spec.hostPreLaunch}
              ;;'') cfg);
in {
  options.custom = {
    flakeDir = mkOption {
      type    = types.str;
      default = "${homePrefix}/${config.custom.username}/.config/nix";
      description = "Absolute path to the nix flake directory (used by vm/builder helpers and rebuild-me alias)";
    };
    microvmDefaults = {
      timeZone = mkOption { type = types.str; default = "Europe/Zurich"; };
      locale   = mkOption { type = types.str; default = "en_US.UTF-8"; };
    };
    microvms = mkOption {
      type        = types.attrsOf (types.submodule vmSubmodule);
      default     = {};
      description = "Development microVMs (vfkit on macOS, qemu/KVM on Linux)";
    };
  };

  config = mkIf (cfg != {}) (mkMerge [
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


          usage() {
            cat <<'EOF'
          Usage: nix-vm <command> [name]  (alias: vm)

          Commands:
            build <name>   Build VM guest image (run before first up, or after rebuild)
            up    <name>   Start VM (bridges KeePassXC agent, attaches console)
            down  <name>   Tear down agent bridge (poweroff inside VM to stop it)
            list           Show defined VMs and bridge status
          EOF
            echo ""
            echo "Defined VMs: $DEFINED_VMS"
          }

          vm_up() {
            local name=$1
            local base_dir="$HOME/.local/state/microvm/$name"
            local persistent="''${VM_PERSISTENT[$name]:-0}"
            local inst_dir
            if [ "$persistent" = 1 ]; then
              # Persistent: fixed base dir; home.img/store.img survive. Single-instance — refuse a
              # second launch (a shared rw image would corrupt).
              inst_dir="$base_dir"
              mkdir -p "$inst_dir"
              if [ -f "$inst_dir/instance.lock" ] && kill -0 "$(cat "$inst_dir/instance.lock" 2>/dev/null)" 2>/dev/null; then
                echo "✗ '$name' is persistent and already running (pid $(cat "$inst_dir/instance.lock")). Not starting a second instance." >&2
                return 1
              fi
            else
              # Ephemeral: per-instance working dir. The guest's volume/socket paths are RELATIVE,
              # so each launch runs from its own dir → concurrent instances, wiped on exit.
              inst_dir="$base_dir/run.$$.$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
              mkdir -p "$inst_dir"
            fi
            cd "$inst_dir" || { echo "cannot enter $inst_dir" >&2; return 1; }
            [ "$persistent" = 1 ] && echo $$ > "$inst_dir/instance.lock"

            # Cleanup trap: kill helper PIDs, drop transient sockets/pids/lock; wipe the whole dir
            # only when ephemeral (persistent keeps home.img/store.img). Values baked in now so the
            # trap stays valid after vm_up returns.
            trap '
              for pf in "'"$inst_dir"'"/*.pid; do
                [ -e "$pf" ] || continue
                kill "$(cat "$pf")" 2>/dev/null || true
              done
              rm -f "'"$inst_dir"'"/*.pid "'"$inst_dir"'"/*.sock "'"$inst_dir"'"/instance.lock
              [ "'"$persistent"'" = 1 ] || rm -rf "'"$inst_dir"'"
            ' EXIT INT TERM

            if [ -n "''${SSH_AUTH_SOCK:-}" ]; then
              if [ "$OS" = "Darwin" ]; then
                # vfkit resolves the guest's relative socketURL (agent.sock) against $inst_dir
                socat UNIX-LISTEN:"$inst_dir/agent.sock",fork,mode=0600 \
                      UNIX-CONNECT:"$SSH_AUTH_SOCK" &
              else
                # Linux/qemu: socat listens on the vsock port. NOTE: the port/CID is baked per VM,
                # so concurrent instances of the SAME VM collide here on qemu (a vfkit-only feature).
                local port="''${VM_VSOCK_PORTS[$name]:?'Unknown VM: use vm list'}"
                socat VSOCK-LISTEN:"$port",reuseaddr,fork \
                      UNIX-CONNECT:"$SSH_AUTH_SOCK" &
              fi
              echo $! > "$inst_dir/bridge.pid"
              echo "→ Agent bridge started (pid $!)"
            else
              echo "⚠  SSH_AUTH_SOCK not set — agent forwarding disabled"
            fi

            # Consumer host hook (credential staging, RAM-disk mounts, …). Runs with CWD = the
            # per-instance dir; in scope: $name, $inst_dir, $OS. Background helpers should write
            # "$inst_dir/<x>.pid" so the trap kills them.
            case "$name" in
            ${hostPreLaunchDispatch}
            esac

            if [ "$persistent" = 1 ]; then
              echo "→ Launching persistent VM '$name'… (poweroff inside to stop)"
            else
              echo "→ Launching VM '$name' (instance ''${inst_dir##*/})… (poweroff inside to stop)"
            fi
            nix run "$FLAKE#microvm-$name"
          }

          vm_build() {
            local name=$1
            echo "→ Building VM '$name'…"
            nix build "$FLAKE#microvm-$name"
            echo "✓ Done"
          }

          vm_down() {
            local name=$1
            local state_dir="$HOME/.local/state/microvm/$name"
            if [ -f "$state_dir/bridge.pid" ]; then
              kill "$(cat "$state_dir/bridge.pid")" 2>/dev/null && \
                echo "→ Agent bridge for '$name' stopped"
              rm -f "$state_dir/bridge.pid"
              [ "$OS" = "Darwin" ] && rm -f "$state_dir/agent.sock"
            else
              echo "No running bridge for '$name'"
            fi
          }

          vm_list() {
            echo "Defined microVMs:"
            for name in $DEFINED_VMS; do
              local state_dir="$HOME/.local/state/microvm/$name"
              if [ -f "$state_dir/bridge.pid" ] && \
                 kill -0 "$(cat "$state_dir/bridge.pid")" 2>/dev/null; then
                echo "  $name  [bridge running]"
              else
                echo "  $name  [stopped]"
              fi
            done
          }

          case "''${1:-}" in
            build)        vm_build "''${2:?'Usage: vm build <name>'}"; ;;
            up)           vm_up   "''${2:?'Usage: vm up <name>'}"; ;;
            down)         vm_down "''${2:?'Usage: vm down <name>'}"; ;;
            list)         vm_list; ;;
            ""|--help|-h) usage; ;;
            *)            echo "Unknown command: ''${1}"; echo; usage; exit 1; ;;
          esac
        '')
      ];
      home-manager.sharedModules = [{ home.shellAliases.vm = "nix-vm"; }];
    }

    # ── macOS only ─────────────────────────────────────────────────────────────
    (mkIf pkgs.stdenv.isDarwin {
      # Register the vfkit linux-builder as a remote build machine.
      # Start it with: builder up
      nix.distributedBuilds = mkIf config.custom.nativeNix true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = mkIf config.custom.nativeNix [{
        hostName          = "linux-builder";
        sshUser           = "builder";
        sshKey            = "/etc/nix/builder_ed25519";
        systems           = [ "aarch64-linux" ];
        maxJobs           = 4;
        supportedFeatures = [ "benchmark" "big-parallel" ];
      }];

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
      home-manager.sharedModules = [{ home.shellAliases.builder = "nix-vm-builder"; }];
    })

    # ── Linux only ─────────────────────────────────────────────────────────────
    (mkIf (!pkgs.stdenv.isDarwin) {
      users.users."${config.custom.username}".extraGroups = [ "kvm" ];
    })
  ]);
}
