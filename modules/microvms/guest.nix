# modules/microvms/guest.nix
# Shared NixOS guest base for all microVMs.
# Receives `vmName` (string) and `vmSpec` (evaluated custom.microvms.<name> attrset)
# from flake.nix via specialArgs.
{ config, pkgs, lib, inputs, vmName, vmSpec, ... }:
let
  # Host-side path prefix: /Users on macOS (vfkit), /home on Linux (qemu).
  # Derived from hypervisor since vfkit→darwin, qemu→linux.
  hostHomePrefix = if vmSpec.hypervisor == "vfkit" then "/Users" else "/home";
  hostHome       = "${hostHomePrefix}/${vmSpec.user}";
  stateDir       = "${hostHome}/.local/state/microvm/${vmName}";
  agentSock      = "${stateDir}/agent.sock";   # only used by vfkit path below

  # Nix store paths for shared pub-key files
  sshPubKeyFiles = lib.mapAttrs' (fname: content:
    lib.nameValuePair ".ssh/${fname}" { text = content; }
  ) vmSpec.sshPubKeys;

  # Resolved extraShares: derive virtiofs tag from basename(mountPoint) when not set
  resolvedExtraShares = map (s: {
    tag        = if s.tag != "" then s.tag else baseNameOf s.mountPoint;
    source     = s.source;
    mountPoint = s.mountPoint;
    proto      = "virtiofs";
  }) vmSpec.extraShares;

  # ── Non-persistent /home backing ──────────────────────────────────────────────
  # tmpfs lives in guest RAM (vmSpec.mem); only sensible when RAM comfortably exceeds home size.
  # "disk" uses a real microvm.volume (a static device the runner lists directly — vfkit's runner
  # discards runtime-appended device args, so a per-launch random image cannot be attached there).
  # Non-persistence comes from the `vm` helper wiping the image on exit; microvm autoCreate then
  # remakes a blank ext4 on the next start.
  homeBackingResolved =
    if vmSpec.homeBacking != "auto" then vmSpec.homeBacking
    else if vmSpec.mem > 2 * vmSpec.homeSize then "tmpfs" else "disk";

in {
  imports = [
    inputs.home-manager.nixosModules.home-manager
  ];

  # ── Nix store overlay (persistent across reboots via a dedicated volume)
  microvm.writableStoreOverlay = "/nix/.rw-store";

  # ── Hardware / hypervisor
  microvm.hypervisor = vmSpec.hypervisor;
  microvm.vcpu       = vmSpec.vcpu;
  microvm.mem        = vmSpec.mem;

  # ── Networking: usermode NAT (outbound internet; no sshd into VM)
  microvm.interfaces = [{
    type = "user";
    id   = "eth0";
    mac  = vmSpec.mac;
  }];

  # ── Virtiofs shares: extra per-VM shares only (secret/mount mechanisms are the
  #    consumer's concern — add more via extraShares or an extraModules NixOS module)
  microvm.shares = resolvedExtraShares;

  # ── Volumes: persistent store overlay + (disk mode) a non-persistent /home image.
  #    The home.img volume is wiped on exit by the `vm` helper and recreated blank by
  #    microvm autoCreate on the next start, so /home never persists across boots.
  microvm.volumes = [
    {
      image      = "${stateDir}/store.img";
      mountPoint = "/nix/.rw-store";
      size       = vmSpec.storeSize;
    }
  ] ++ lib.optional (homeBackingResolved == "disk") {
    image      = "${stateDir}/home.img";
    mountPoint = "/home";
    size       = vmSpec.homeSize;
  };

  # tmpfs mode: /home is RAM-backed (no host device). disk mode mounts /home from the volume above.
  fileSystems."/home" = lib.mkIf (homeBackingResolved == "tmpfs") {
    device  = "tmpfs";
    fsType  = "tmpfs";
    options = [ "mode=0755" "size=${toString vmSpec.homeSize}m" ];
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
  microvm.vmHostPackages = lib.mkIf (vmSpec.hypervisor == "vfkit")
    inputs.nixpkgs.legacyPackages.aarch64-darwin;

  microvm.vfkit.extraArgs = lib.mkIf (vmSpec.hypervisor == "vfkit") ([
    "--device"
    "virtio-vsock,port=${toString vmSpec.vsockPort},socketURL=${agentSock}"
  ] ++ vmSpec.vfkitExtraArgs);

  # Guest vsock CID for qemu/vhost-vsock. We reuse vsockPort as CID (≥1024, above reserved range).
  microvm.vsock.cid = lib.mkIf (vmSpec.hypervisor == "qemu") vmSpec.vsockPort;

  # ── Networking config inside the guest
  networking.hostName    = vmName;
  networking.useDHCP     = true;   # DHCP on all interfaces; hypervisor NAT provides connectivity
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  # ── Packages: base toolset (project-specific tools come from each repo's nix develop)
  environment.systemPackages = with pkgs; [
    git
    gh
    claude-code
    ripgrep
    fzf
    jq
    socat
    curl
    tree
    htop
  ];

  # ── Nix settings
  nix.package = pkgs.nix;
  nix.settings = {
    experimental-features = "nix-command flakes";
    trusted-users         = [ "root" vmSpec.user ];
    substituters          = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCUSids="
    ];
  };

  # ── nixpkgs config: overlay + unfree (claude-code requires allowUnfree)
  nixpkgs.overlays         = [ inputs.nixneovimplugins.overlays.default ];
  nixpkgs.config.allowUnfree = true;

  # ── Guest user (mirrors host username)
  users.users.${vmSpec.user} = {
    isNormalUser = true;
    shell        = pkgs.zsh;
    extraGroups  = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

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

  # ── KeePassXC agent bridge service
  #    Connects out to the host vsock listener (CID 2 = host on both vfkit and qemu vhost-vsock)
  #    and presents the forwarded agent as a local unix socket.
  systemd.services.keepassxc-agent = {
    description = "KeePassXC SSH agent bridge (guest → host via virtio-vsock)";
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      Type          = "simple";
      ExecStart     = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/ssh-agent/agent.sock,fork,mode=0666 VSOCK-CONNECT:2:${toString vmSpec.vsockPort}";
      Restart       = "on-failure";
      RestartSec    = "5s";
      RuntimeDirectory     = "ssh-agent";
      RuntimeDirectoryMode = "0755";
    };
  };

  # Make SSH_AUTH_SOCK point to the forwarded agent for all login sessions
  environment.variables.SSH_AUTH_SOCK = "/run/ssh-agent/agent.sock";

  # ── Timezone + locale (match the host)
  time.timeZone      = vmSpec.timeZone;
  i18n.defaultLocale = vmSpec.locale;

  # ── Clock resync after host sleep (chrony's makestep jumps immediately when offset > 1 s)
  services.chrony = {
    enable      = true;
    servers     = [ "pool.ntp.org" ];
    extraConfig = "makestep 1 -1";
  };

  # ── home-manager in guest
  # hmModules = shared base (home-manager/home.nix); extraHmModules = per-VM user layer
  # (set via custom.microvms.<name>.extraHmModules in the consuming host config).
  # darwin-only bits in the user layer are guarded with lib.optionals/mkIf pkgs.stdenv.isDarwin
  # so they no-op on the aarch64-linux guest (isDarwin = false here).
  home-manager = {
    useGlobalPkgs       = true;   # use NixOS system pkgs (aarch64-linux, with overlays applied)
    useUserPackages     = true;
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

  system.stateVersion = "24.05";
}
