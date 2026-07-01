# modules/nixos/core.nix
# NixOS workstation base — hardware-agnostic.
# Each host provides its own hardware-configuration.nix via hosts/<name>/.
{ config, pkgs, lib, hostname, ... }: {
  # ── Boot (UEFI / systemd-boot)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking
  networking.hostName = hostname;
  networking.networkmanager.enable = true;
  users.users."${config.custom.username}".extraGroups = [ "networkmanager" ];

  # ── Audio (pipewire replaces pulseaudio)
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ── SSH server (workstation admin / remote access)
  services.openssh.enable = true;

  # ── Locale / timezone (match darwin defaults; override per-host if needed)
  time.timeZone = "Europe/Zurich";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Primary user
  users.users."${config.custom.username}" = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "audio" "video" "input" ];
  };
  security.sudo.wheelNeedsPassword = true;

  # ── Nix-level zsh (NixOS-specific option names)
  programs.zsh.syntaxHighlighting.enable = true;
  programs.zsh.autosuggestions.enable = true;

  environment.shellAliases.rebuild-me = "sudo nixos-rebuild switch --flake ${config.custom.flakeDir}";

  # ── System state version (NixOS convention)
  system.stateVersion = "24.05";
}
