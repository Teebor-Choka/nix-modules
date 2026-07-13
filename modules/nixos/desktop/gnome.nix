# modules/nixos/desktop/gnome.nix
# GNOME Wayland desktop. Import from the host's modules list.
# Swap for sway.nix / hyprland.nix by changing the host's modules entry.
{ pkgs, ... }: {
  # Display server + desktop manager
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.displayManager.gdm.wayland = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Keyboard layout (override per-host if needed)
  services.xserver.xkb = {
    layout = "us";
    options = "terminate:ctrl_alt_bksp";
  };

  # Remove heavy GNOME bloat from the default package set
  environment.gnome.excludePackages = with pkgs.gnome; [
    epiphany # web browser
    totem # video player
    yelp # help browser
  ];

  # Useful extras that GNOME doesn't include by default
  environment.systemPackages = with pkgs; [
    gnome-tweaks
    dconf-editor
  ];
}
