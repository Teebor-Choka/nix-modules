# modules/shared/default.nix
# Cross-platform configuration shared by darwin and nixos hosts.
# Only options that exist (with the same name) on both nix-darwin and NixOS live here.
{ config, pkgs, inputs, ... }: {
  # nixpkgs: nvim-plugins overlay + unfree (claude-code, etc.)
  nixpkgs.overlays = [ inputs.nixneovimplugins.overlays.default ];
  nixpkgs.config.allowUnfree = true;

  # Shells (platform-specific zsh extras live in the per-platform core modules)
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    shellInit = ''
      eval "$(direnv hook zsh)"
      export PATH=$HOME/.local/bin:$PATH
    '';
  };
  programs.bash.enable = true;

  # Dev ergonomics
  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
  programs.gnupg.agent.enable = true;
  programs.gnupg.agent.enableSSHSupport = false;

  environment.variables.EDITOR = "vim";
  environment.shellAliases.sudo = "sudo ";

  fonts.packages = [ pkgs.iosevka-bin pkgs.roboto pkgs.source-code-pro ];

  # Home-manager wiring. The module import (darwinModules vs nixosModules) is selected
  # per-class in flake.nix; this configuration is identical on both.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    sharedModules = [ ../../home-manager/home.nix ];
    users."${config.custom.username}" = {};
  };
}
