# home-manager/home.nix
{ pkgs, ... }: {
  imports = [ ./git-clone.nix ];

  home.stateVersion = "24.05";

  # Tiny, universal utilities everyone should have
  home.packages = with pkgs; [
    coreutils
    rsync
    tree
    unixtools.watch
  ];

  programs.htop.enable = true;
  programs.htop.settings.show_program_path = true;

  # Let individual modules or users override or extend these safely
  programs.zsh.enable = true;
  programs.bash.enable = true;
}
