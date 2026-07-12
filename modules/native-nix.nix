{
  config,
  pkgs,
  lib,
  ...
}:
lib.mkIf config.custom.nativeNix {
  nix.enable = true;
  nix.package = pkgs.nix;
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.trusted-users = [
    "@admin"
    config.custom.username
  ];
  nix.optimise.automatic = true;
  nix.gc = {
    automatic = true;
    options = "--delete-older-than 30d";
  };
}
