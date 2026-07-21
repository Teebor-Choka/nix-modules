# modules/microvms/guest.nix
# Shared NixOS guest base for all microVMs.
# Receives `vmName` (string) and `vmSpec` (evaluated custom.microvms.<name> attrset)
# from flake.nix via specialArgs.
{
  pkgs,
  lib,
  inputs,
  vmName,
  vmSpec,
  ...
}:
let
  # Host-side path prefix: /Users on macOS (vfkit), /home on Linux (qemu).
  # Derived from hypervisor since vfkit→darwin, qemu→linux.
  hostHomePrefix = if vmSpec.hypervisor == "vfkit" then "/Users" else "/home";
  hostHome = "${hostHomePrefix}/${vmSpec.user}";
  stateDir = "${hostHome}/.local/state/microvm/${vmName}";

  # Share the host /nix/store read-only (vs a per-VM EROFS image). Immutable → safe across
  # concurrent instances. Adding this share flips microvm.storeOnDisk to false automatically.
  shareHostStore = vmSpec.storeBacking == "host";

  # Nix store paths for shared pub-key files
  sshPubKeyFiles = lib.mapAttrs' (
    fname: content: lib.nameValuePair ".ssh/${fname}" { text = content; }
  ) vmSpec.sshPubKeys;

  # Resolved extraShares: derive virtiofs tag from basename(mountPoint) when not set
  resolvedExtraShares = map (s: {
    inherit (s) source mountPoint;
    tag = if s.tag != "" then s.tag else baseNameOf s.mountPoint;
    proto = "virtiofs";
  }) vmSpec.extraShares;

  # ── Non-persistent /home backing ──────────────────────────────────────────────
  # tmpfs lives in guest RAM (vmSpec.mem); only sensible when RAM comfortably exceeds home size.
  # "disk" uses a real microvm.volume (a static device the runner lists directly — vfkit's runner
  # discards runtime-appended device args, so a per-launch random image cannot be attached there).
  # Non-persistence comes from the `vm` helper wiping the image on exit; microvm autoCreate then
  # remakes a blank ext4 on the next start.
  homeBackingResolved =
    if vmSpec.persistent then
      "disk" # tmpfs can't persist across boots
    else if vmSpec.homeBacking != "auto" then
      vmSpec.homeBacking
    else if vmSpec.mem > 2 * vmSpec.homeSize then
      "tmpfs"
    else
      "disk";

in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ./secrets.nix # generic secret injection (no-op unless vmSpec.secrets is set)
  ];

  # ── Writable store overlay: per-instance RAM. With no volume backing it, the upperdir lives
  #    on the root tmpfs, so it is isolated per instance and wiped when the VM stops.
  microvm.writableStoreOverlay = "/nix/.rw-store";

  # ── Hardware / hypervisor
  microvm.hypervisor = vmSpec.hypervisor;
  microvm.vcpu = vmSpec.vcpu;
  microvm.mem = vmSpec.mem;

  # ── Networking: usermode NAT (outbound internet; no sshd into VM)
  microvm.interfaces = [
    {
      type = "user";
      id = "eth0";
      mac = vmSpec.mac;
    }
  ];

  # ── Virtiofs shares: extra per-VM shares, plus the read-only host store (host mode).
  #    The /nix/store share makes microvm.storeOnDisk=false (host store instead of an EROFS image).
  microvm.shares =
    resolvedExtraShares
    ++ lib.optional shareHostStore {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    # Secret staging area (host stages secrets/secret-<i> here; secrets.nix reads + wipes them).
    ++ lib.optional (vmSpec.secrets != [ ]) {
      source = "secrets";
      mountPoint = "/run/injected-secrets";
      tag = "injected-secrets";
      proto = "virtiofs";
    };

  # ── Volumes (RELATIVE image paths → resolved against the launch's working dir):
  #    - persistent VMs get a writable store.img (overlay persists → package cache) at the fixed
  #      base dir; ephemeral VMs get no store.img (overlay lives on rootfs tmpfs, per-instance).
  #    - disk-mode /home gets a home.img (persistent at base dir, or per-instance & wiped).
  microvm.volumes =
    lib.optional vmSpec.persistent {
      image = "store.img";
      mountPoint = "/nix/.rw-store";
      size = vmSpec.storeSize;
    }
    ++ lib.optional (homeBackingResolved == "disk") {
      image = "home.img";
      mountPoint = "/home";
      size = vmSpec.homeSize;
    };

  # tmpfs mode: /home is RAM-backed (no host device). disk mode mounts /home from the volume above.
  fileSystems."/home" = lib.mkIf (homeBackingResolved == "tmpfs") {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "mode=0755"
      "size=${toString vmSpec.homeSize}m"
    ];
  };

  # ── Agent device attach — conditional per hypervisor ─────────────────────────
  #
  #  vfkit (macOS):
  #    microvm.vmHostPackages must be set to darwin pkgs so the vfkit runner's platform
  #    check passes (its default is the guest's aarch64-linux pkgs, which fails the check).
  #    The host `vm up` places a unix socket at agentSock (bridged from $SSH_AUTH_SOCK).
  #    vfkit listens on that unix socket and presents it as a virtio-vsock device to the guest.
  #    The guest service (below) connects out to CID 2:vsockPort and exposes the agent.
  #
  #  qemu (Linux):
  #    microvm.vsock.cid adds a vhost-vsock device; each VM gets a unique guest CID.
  #    The host `vm up` runs socat VSOCK-LISTEN:<vsockPort> directly (no unix socket relay).
  #    The guest service connects identically: VSOCK-CONNECT:2:vsockPort.
  # ─────────────────────────────────────────────────────────────────────────────

  # Supply darwin host packages so the vfkit runner's isDarwin check passes.
  # Without this, vmHostPackages defaults to the guest's aarch64-linux pkgs → build error.
  microvm.vmHostPackages = lib.mkIf (
    vmSpec.hypervisor == "vfkit"
  ) inputs.nixpkgs.legacyPackages.aarch64-darwin;

  # vfkit extra args: consumer additions only. The SSH agent no longer uses VSOCK here
  # (vfkit 0.6.x VSOCK relay is broken — see default.nix). TCP relay is used instead.
  microvm.vfkit.extraArgs = lib.mkIf (vmSpec.hypervisor == "vfkit") vmSpec.vfkitExtraArgs;

  # Guest vsock CID for qemu/vhost-vsock. We reuse vsockPort as CID (≥1024, above reserved range).
  microvm.vsock.cid = lib.mkIf (
    vmSpec.hypervisor == "qemu" && vmSpec.forwardSshAgent
  ) vmSpec.vsockPort;

  # ── Networking config inside the guest
  networking.hostName = vmName;
  networking.useDHCP = true; # DHCP on all interfaces; hypervisor NAT provides connectivity
  networking.nameservers = vmSpec.nameservers;

  # ── Packages: minimal base only. socat is required (SSH-agent bridge); the rest are small,
  #    universal CLI tools. Everything else (gh, editors, language toolchains, AI CLIs, …) is
  #    consumer-specific — add it per VM via extraModules / extraHmModules.
  environment.systemPackages =
    (with pkgs; [
      socat # required: SSH-agent vsock bridge
      git
      curl
      jq
      ripgrep
      fzf
    ])
    ++ vmSpec.extraPackages pkgs; # consumer additions, resolved against the guest's pkgs

  # ── Nix settings
  nix.package = pkgs.nix;
  nix.settings = {
    experimental-features = "nix-command flakes";
    trusted-users = [
      "root"
      vmSpec.user
    ];
    substituters = vmSpec.substituters;
    trusted-public-keys = vmSpec.trustedPublicKeys;
  };

  # ── nixpkgs config: consumer-provided overlays + unfree policy (default none/false).
  nixpkgs.overlays = vmSpec.overlays;
  nixpkgs.config.allowUnfree = vmSpec.allowUnfree;

  # ── Guest user (mirrors host username)
  users.users.${vmSpec.user} = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = lib.mkIf vmSpec.guestSSH.enable vmSpec.guestSSH.authorizedKeys;
  };
  security.sudo.wheelNeedsPassword = false;

  # ── Optional guest sshd (host→guest debugging / verification). Usermode NAT means it is not
  #    directly routable — reach it via a host port-forward to the guest IP. Keys-only (no password).
  services.openssh = lib.mkIf vmSpec.guestSSH.enable {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # Create the user home dir on the (possibly fresh) ext4 home volume.
  # systemd-tmpfiles-setup runs after local-fs.target (all mounts done), so this
  # is guaranteed to write to the mounted home.img rather than the read-only EROFS.
  # Also pre-creates ~/.local/state/nix/profiles so home-manager activation succeeds.
  systemd.tmpfiles.rules = [
    "d /home/${vmSpec.user}                           0700 ${vmSpec.user} users - -"
    "d /home/${vmSpec.user}/.local                    0700 ${vmSpec.user} users - -"
    "d /home/${vmSpec.user}/.local/state              0700 ${vmSpec.user} users - -"
    "d /home/${vmSpec.user}/.local/state/nix          0700 ${vmSpec.user} users - -"
    "d /home/${vmSpec.user}/.local/state/nix/profiles 0700 ${vmSpec.user} users - -"
  ];

  # Autologin on serial console
  services.getty.autologinUser = lib.mkIf vmSpec.autologin vmSpec.user;

  # ── Shell: zsh as default for the system
  programs.zsh.enable = true;

  # ── Forwarded SSH-agent bridge (tool-agnostic: forwards the host's $SSH_AUTH_SOCK).
  #    Connects out to the host vsock listener (CID 2 = host on both vfkit and qemu vhost-vsock)
  #    and presents the forwarded agent as a local unix socket. Opt-out via forwardSshAgent = false.
  systemd.services.ssh-agent-bridge = lib.mkIf vmSpec.forwardSshAgent {
    description = "Forwarded SSH agent (guest → host over virtio-vsock)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart =
        let
          # vfkit: TCP to host NAT gateway (192.168.65.1) — VSOCK relay broken in vfkit 0.6.x.
          # qemu: VSOCK-CONNECT to the host (CID 2) on the configured vsock port.
          target =
            if vmSpec.hypervisor == "vfkit" then
              "TCP:192.168.65.1:${toString vmSpec.vsockPort}"
            else
              "VSOCK-CONNECT:2:${toString vmSpec.vsockPort}";
        in
        "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/ssh-agent/agent.sock,fork,mode=0666 ${target}";
      Restart = "on-failure";
      RestartSec = "5s";
      RuntimeDirectory = "ssh-agent";
      RuntimeDirectoryMode = "0755";
    };
  };

  # Point SSH_AUTH_SOCK at the forwarded agent for all login sessions (when enabled).
  environment.variables = lib.mkIf vmSpec.forwardSshAgent {
    SSH_AUTH_SOCK = "/run/ssh-agent/agent.sock";
  };

  # ssh-agent-bridge is Type=simple: systemd marks it "active" the moment socat forks,
  # before the UNIX socket at /run/ssh-agent/agent.sock actually exists. home-manager
  # activation may run home.gitClone (which needs SSH_AUTH_SOCK), so we interpose a oneshot
  # "ready" service that polls until the socket appears, and order home-manager after it.
  systemd.services.ssh-agent-bridge-ready = lib.mkIf vmSpec.forwardSshAgent {
    description = "Wait for SSH agent bridge socket to be ready";
    after = [ "ssh-agent-bridge.service" ];
    requires = [ "ssh-agent-bridge.service" ];
    before = [ "home-manager-${vmSpec.user}.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "ssh-agent-bridge-wait" ''
        for i in $(seq 30); do
          [ -S /run/ssh-agent/agent.sock ] && exit 0
          sleep 1
        done
        echo "ssh-agent socket did not appear after 30s" >&2
        exit 1
      '';
    };
  };

  systemd.services."home-manager-${vmSpec.user}" = lib.mkIf vmSpec.forwardSshAgent {
    after = [ "ssh-agent-bridge-ready.service" ];
    wants = [ "ssh-agent-bridge-ready.service" ];
    environment.SSH_AUTH_SOCK = "/run/ssh-agent/agent.sock";
  };

  # GitHub SSH host keys — pre-trusted so home.gitClone over SSH doesn't fail on first boot.
  # Writes to /etc/ssh/ssh_known_hosts (system-wide). Rotate if GitHub announces a key change.
  programs.ssh.knownHosts = {
    "github.com" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    "github.com-ecdsa" = {
      hostNames = [ "github.com" ];
      publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    };
  };

  # ── Timezone + locale (match the host)
  time.timeZone = vmSpec.timeZone;
  i18n.defaultLocale = vmSpec.locale;

  # ── Clock resync after host sleep (chrony's makestep jumps immediately when offset > 1 s)
  services.chrony = {
    enable = true;
    servers = vmSpec.ntpServers;
    extraConfig = "makestep 1 -1";
  };

  # ── home-manager in guest
  # hmModules = shared base (home-manager/home.nix); extraHmModules = per-VM user layer
  # (set via custom.microvms.<name>.extraHmModules in the consuming host config).
  # darwin-only bits in the user layer are guarded with lib.optionals/mkIf pkgs.stdenv.isDarwin
  # so they no-op on the aarch64-linux guest (isDarwin = false here).
  home-manager = {
    useGlobalPkgs = true; # use NixOS system pkgs (aarch64-linux, with overlays applied)
    useUserPackages = true;
    backupFileExtension = "backup";
    users.${vmSpec.user} = {
      imports = vmSpec.hmModules ++ vmSpec.extraHmModules;

      # Per-VM SSH config (host aliases for account key selection)
      home.file = lib.mkMerge [
        (lib.mkIf (vmSpec.sshConfig != "") {
          ".ssh/config".text = vmSpec.sshConfig;
        })
        sshPubKeyFiles
      ];
    };
  };

  boot.initrd.systemd.enable = true;

  assertions = [
    {
      assertion = !vmSpec.forwardSshAgent || vmSpec.vsockPort != null;
      message = "microVM '${vmName}': forwardSshAgent = true requires vsockPort to be set.";
    }
  ];

  system.stateVersion = "24.05";
}
