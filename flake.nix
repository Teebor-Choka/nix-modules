{
  description = "Reusable nix-darwin + NixOS + home-manager modules (microVMs, linux-builder, shared tooling)";

  # No inputs — this is a module-source flake.
  # Consumers declare all their own inputs (nixpkgs, home-manager, microvm, …) and pass them
  # to these modules via `specialArgs = { inherit inputs; }`.
  outputs = { self }: {

    # ── home-manager module ────────────────────────────────────────────────────
    # Generic base: coreutils, htop, zsh/bash enable.
    # Import as: inputs.nix-modules.homeManagerModules.default
    homeManagerModules.default = ./home-manager/home.nix;

    # ── darwin system module ───────────────────────────────────────────────────
    # macOS host config: Homebrew wiring, TouchID sudo, Spotlight alias, zsh extras.
    # Import as: inputs.nix-modules.darwinModules.default
    darwinModules.default = ./modules/darwin/core.nix;

    # ── NixOS system modules ───────────────────────────────────────────────────
    nixosModules = {
      # NixOS workstation base: systemd-boot, NetworkManager, pipewire, SSH server.
      core         = ./modules/nixos/core.nix;
      # GNOME/Wayland desktop via GDM.
      gnome        = ./modules/nixos/desktop/gnome.nix;
      # Shared NixOS guest base for microVM sandboxes.
      microvmGuest = ./modules/microvms/guest.nix;
      # Minimal NixOS guest for the vfkit linux-builder (cross-build aarch64-linux on macOS).
      builderGuest = ./modules/builder/guest.nix;
    };

    # ── Platform-neutral system modules ───────────────────────────────────────
    # Non-standard attr (nix flake check warns, doesn't fail — these are raw module paths).
    # Import each as: inputs.nix-modules.nixModules.<key>
    nixModules = {
      # custom.* option declarations (username, hostname, homebrew, flakeDir, microvms).
      options   = ./modules/options.nix;
      # Nix daemon settings: binary caches, experimental-features, GC, store optimisation.
      nativeNix = ./modules/native-nix.nix;
      # Cross-platform base: nixneovimplugins overlay, zsh, direnv, GPG, fonts, home-manager wiring.
      shared    = ./modules/shared;           # → modules/shared/default.nix
      # Host-side microVM module: custom.microvms option schema, vm/builder shell helpers.
      microvms  = ./modules/microvms/default.nix;
    };
  };
}
