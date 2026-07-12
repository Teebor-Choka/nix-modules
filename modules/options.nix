{ lib, ... }:
with lib; {
  options.custom = {
    username = mkOption { type = types.str; description = "The primary system username"; };
    hostname = mkOption { type = types.str; default = ""; description = "The machine hostname (informational; hosts set networking.hostName from the specialArg)"; };
    nativeNix = mkOption {
      type = types.bool;
      default = false;
      description = "Enable native Nix settings. Set to false if using the Determinate Installer.";
    };
    # Shared-base host conventions (defaults preserve prior hardcoded behavior).
    editor = mkOption { type = types.str; default = "vim"; description = "Default $EDITOR (shared base)."; };
    shellAliases = mkOption {
      type = types.attrsOf types.str;
      default = { sudo = "sudo "; };   # trailing space → alias-expand the next word
      description = "System shell aliases set by the shared base.";
    };
    enableDirenv = mkOption { type = types.bool; default = true; description = "Enable direnv + nix-direnv and the zsh hook (shared base)."; };
    enableGnupgAgent = mkOption { type = types.bool; default = true; description = "Enable the GnuPG agent (shared base)."; };
    fonts = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Font packages to install system-wide";
    };
    overlays = mkOption {
      type = types.listOf (mkOptionType {
        name = "nixpkgs-overlay";
        check = lib.isFunction;
        merge = lib.mergeOneOption;
      });
      default = [];
      description = "nixpkgs overlays to apply system-wide (host + guests). Empty by default.";
    };
    allowUnfree = mkOption {
      type = types.bool;
      default = false;
      description = "Set nixpkgs.config.allowUnfree system-wide (host + guests).";
    };
    homebrew = {
      taps = mkOption { type = types.listOf types.str; default = []; };
      brews = mkOption { type = types.listOf types.str; default = []; };
      casks = mkOption { type = types.listOf types.str; default = []; };
      masApps = mkOption { type = types.attrsOf types.ints.unsigned; default = {}; };
    };
  };
}
