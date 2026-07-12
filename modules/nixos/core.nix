# modules/nixos/core.nix
# NixOS workstation base — hardware-agnostic.
# Each host provides its own hardware-configuration.nix via hosts/<name>/.
{
  config,
  pkgs,
  lib,
  hostname,
  ...
}:
{
  # ── Boot (UEFI / systemd-boot)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking
  networking.hostName = hostname;
  networking.networkmanager.enable = true;

  # ── Audio (pipewire replaces pulseaudio)
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ── SSH server — cattle control plane (push deploys depend on this; never disable)
  services.openssh = {
    enable = true;
    openFirewall = lib.mkDefault true; # port 22 reachable; anti-lockout for push deploy
    settings = {
      PasswordAuthentication = lib.mkDefault false; # keys only
      KbdInteractiveAuthentication = lib.mkDefault false;
      PermitRootLogin = lib.mkDefault "no";
    };
  };

  # ── Locale / timezone (match darwin defaults; override per-host if needed)
  time.timeZone = lib.mkDefault "Europe/Zurich";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  # ── Primary user
  users.users."${config.custom.username}" = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
      "audio"
      "video"
      "input"
      "networkmanager"
    ];
  };
  security.sudo.wheelNeedsPassword = true;

  # ── Nix-level zsh (NixOS-specific option names)
  programs.zsh.syntaxHighlighting.enable = true;
  programs.zsh.autosuggestions.enable = true;

  environment.shellAliases.rebuild-me = "sudo nixos-rebuild switch --flake ${config.custom.flakeDir}";

  # ── System state version — overridable so each host can pin its own original value
  system.stateVersion = lib.mkDefault "24.05";
}
