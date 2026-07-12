{ lib, ... }:
with lib; {
  options.custom = {
    username = mkOption { type = types.str; description = "The primary system username"; };
    hostname = mkOption { type = types.str; description = "The machine hostname"; };
    nativeNix = mkOption { 
      type = types.bool; 
      default = false; 
      description = "Enable native Nix settings. Set to false if using the Determinate Installer."; 
    };
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
