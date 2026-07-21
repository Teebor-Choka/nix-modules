# home-manager/home.nix
{ pkgs, ... }: {
  imports = [
    ./git-clone.nix
    ./git-refresh.nix # opt-in: home.gitRefresh.enable — keep gitClone checkouts current
    ./skill-link.nix # opt-in: home.skillLink — flatten SKILL.md dirs into ~/.claude/skills
  ];

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
