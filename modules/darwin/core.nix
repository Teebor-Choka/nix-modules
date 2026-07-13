# modules/darwin/core.nix
# macOS (nix-darwin) host configuration. Cross-platform bits live in modules/shared.
{
  config,
  pkgs,
  inputs,
  lib,
  hostname,
  ...
}:
{
  # Network identities
  networking.hostName = hostname;
  networking.localHostName = hostname;
  networking.knownNetworkServices = [
    "Wi-Fi"
    "Thunderbolt Ethernet"
  ];

  # darwin-specific zsh extras (these option names are nix-darwin-only)
  programs.zsh.enableSyntaxHighlighting = true;
  programs.zsh.enableFzfCompletion = true;
  programs.zsh.enableFzfHistory = true;
  programs.bash.completion.enable = true;

  environment.systemPackages = with pkgs; [ mkalias ];
  environment.shellAliases.rebuild-me = "sudo darwin-rebuild switch --flake ${config.custom.flakeDir}";

  security.pam.services.sudo_local.touchIdAuth = true;

  # Preserve SSH agent socket through sudo so darwin-rebuild switch
  # can reach the user's SSH agent (KeepassXC, etc.) for git clones.
  security.sudo.extraConfig = "Defaults env_keep += \"SSH_AUTH_SOCK\"";

  # Homebrew
  homebrew = {
    enable = true;
    prefix = "/opt/homebrew";
    global.brewfile = true;
    onActivation = {
      autoUpdate = false;
      cleanup = "zap";
      upgrade = true;
    };
    taps = config.custom.homebrew.taps;
    brews = config.custom.homebrew.brews;
    casks = config.custom.homebrew.casks;
    masApps = config.custom.homebrew.masApps;
  };

  # Nix-Homebrew bridge
  nix-homebrew = {
    enable = true;
    enableRosetta = false;
    user = config.custom.username;
    autoMigrate = true;
  };

  system.primaryUser = config.custom.username;
  system.stateVersion = 5;

  # Spotlight app indexing for Nix-installed apps
  system.activationScripts.applications.text =
    let
      env = pkgs.buildEnv {
        name = "system-applications";
        paths = config.environment.systemPackages;
        pathsToLink = [ "/Applications" ];
      };
    in
    lib.mkForce ''
      echo "Setting up /Applications..." >&2
      rm -rf /Applications/Nix\ Apps
      mkdir -p /Applications/Nix\ Apps
      find ${env}/Applications -maxdepth 1 -type l -exec readlink '{}' + |
      while read -r src; do
        app_name=$(basename "$src")
        echo "copying $src" >&2
        ${pkgs.mkalias}/bin/mkalias "$src" "/Applications/Nix Apps/$app_name"
      done
    '';

  users.users."${config.custom.username}" = {
    name = config.custom.username;
    home = "/Users/${config.custom.username}";
  };
}
