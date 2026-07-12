{
  description = "Reusable nix-darwin + NixOS + home-manager modules (microVMs, linux-builder, shared tooling)";

  # These inputs are TEST-ONLY: used solely by `checks` to instantiate a sample microVM guest so
  # `nix flake check` validates the modules standalone. Consumers still declare their OWN inputs and
  # pass them to these modules via `specialArgs = { inherit inputs; }` — they do not depend on these.
  # (Consumers should add `nix-modules.inputs.<name>.follows = "<name>"` to dedupe their lock.)
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    nixneovimplugins.url = "github:NixNeovim/nixpkgs-vim-extra-plugins";
    nixneovimplugins.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, home-manager, microvm, nixneovimplugins }:
  let
    lib = nixpkgs.lib;

    # ── module outputs (raw paths — consumers import these) ─────────────────────
    moduleOutputs = {
      homeManagerModules.default = ./home-manager/home.nix;
      darwinModules.default      = ./modules/darwin/core.nix;
      nixosModules = {
        core         = ./modules/nixos/core.nix;
        gnome        = ./modules/nixos/desktop/gnome.nix;
        microvmGuest = ./modules/microvms/guest.nix;
        builderGuest = ./modules/builder/guest.nix;
      };
      nixModules = {
        options   = ./modules/options.nix;
        nativeNix = ./modules/native-nix.nix;
        shared    = ./modules/shared;
        microvms  = ./modules/microvms/default.nix;
      };
    };

    # ── microVM guest self-check ────────────────────────────────────────────────
    # A minimal, hand-built vmSpec (mirrors the custom.microvms.<name> submodule fields the guest
    # reads). Instantiating the guest against it forces full evaluation of guest.nix + the runner,
    # catching option/type/wiring regressions without a consumer flake.
    mkSpec = overrides: {
      hypervisor = "qemu"; vcpu = 2; mem = 4096; homeSize = 2048; storeSize = 2048;
      user = "tester"; timeZone = "UTC"; locale = "en_US.UTF-8"; autologin = true;
      mac = "02:00:00:00:00:01"; hmModules = [ ./home-manager/home.nix ]; extraHmModules = [];
      sshConfig = ""; sshPubKeys = {}; vsockPort = 9999; extraShares = [];
      vfkitExtraArgs = []; extraModules = []; homeBacking = "auto";
      persistent = false; storeBacking = "host";
    } // overrides;

    mkGuest = guestSystem: spec: nixpkgs.lib.nixosSystem {
      system = guestSystem;
      specialArgs = { inherit inputs; vmName = "smoke"; vmSpec = spec; };
      modules = [ microvm.nixosModules.microvm self.nixosModules.microvmGuest ];
    };

    # Force both the system closure and the hypervisor runner to evaluate; discard context so the
    # check builds on the host without building the aarch64-linux closure.
    guestDrvs = g: map builtins.unsafeDiscardStringContext [
      g.config.system.build.toplevel.drvPath
      g.config.microvm.declaredRunner.drvPath
    ];

    # Coverage: host-store + ephemeral (default), per-VM EROFS + persistent, tmpfs home, and the
    # vfkit runner (needs matching aarch64 guest + darwin vmHostPackages, set inside guest.nix).
    variants = [
      (mkGuest "aarch64-linux" (mkSpec {}))
      (mkGuest "aarch64-linux" (mkSpec { storeBacking = "image"; persistent = true; }))
      (mkGuest "aarch64-linux" (mkSpec { homeBacking = "tmpfs"; }))
      (mkGuest "aarch64-linux" (mkSpec { hypervisor = "vfkit"; }))
    ];

    checkSystems = [ "aarch64-darwin" "x86_64-linux" ];
    selfChecks = lib.genAttrs checkSystems (hostSys:
      let
        pkgs = nixpkgs.legacyPackages.${hostSys};
        drvs = lib.concatMap guestDrvs variants;
      in {
        microvm-guest-eval = pkgs.runCommand "microvm-guest-eval" { } ''
          printf '%s\n' ${lib.escapeShellArgs drvs} > "$out"
        '';
      });
  in
  moduleOutputs // { checks = selfChecks; };
}
