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

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      microvm,
      nixneovimplugins,
    }:
    let
      lib = nixpkgs.lib;

      # ── module outputs (raw paths — consumers import these) ─────────────────────
      # All modules live under the recognized `nixosModules` / `darwinModules` / `homeManagerModules`
      # outputs (so `nix flake check` stays warning-free). The cross-platform ones (options, nativeNix,
      # shared, microvms) use only options common to nix-darwin and NixOS, so they import cleanly on
      # both — the `nixosModules` label is a namespace, not a platform restriction.
      moduleOutputs = {
        homeManagerModules.default = ./home-manager/home.nix;
        darwinModules.default = ./modules/darwin/core.nix;
        nixosModules = {
          core = ./modules/nixos/core.nix;
          gnome = ./modules/nixos/desktop/gnome.nix;
          microvmGuest = ./modules/microvms/guest.nix;
          builderGuest = ./modules/builder/guest.nix;
          # Cross-platform (darwin + nixos):
          options = ./modules/options.nix;
          nativeNix = ./modules/native-nix.nix;
          shared = ./modules/shared;
          microvms = ./modules/microvms/default.nix;
        };
      };

      # ── microVM guest self-check ────────────────────────────────────────────────
      # A minimal, hand-built vmSpec (mirrors the custom.microvms.<name> submodule fields the guest
      # reads). Instantiating the guest against it forces full evaluation of guest.nix + the runner,
      # catching option/type/wiring regressions without a consumer flake.
      mkSpec =
        overrides:
        {
          hypervisor = "qemu";
          vcpu = 2;
          mem = 4096;
          homeSize = 2048;
          storeSize = 2048;
          user = "tester";
          timeZone = "UTC";
          locale = "en_US.UTF-8";
          autologin = true;
          mac = "02:00:00:00:00:01";
          hmModules = [ ./home-manager/home.nix ];
          extraHmModules = [ ];
          sshConfig = "";
          sshPubKeys = { };
          forwardSshAgent = true;
          vsockPort = 9999;
          extraShares = [ ];
          vfkitExtraArgs = [ ];
          extraModules = [ ];
          homeBacking = "auto";
          persistent = false;
          storeBacking = "host";
          overlays = [ ];
          allowUnfree = false;
          extraPackages = _: [ ];
          ntpServers = [ "pool.ntp.org" ];
          nameservers = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          substituters = [ "https://cache.nixos.org/" ];
          trustedPublicKeys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
        }
        // overrides;

      mkGuest =
        guestSystem: spec:
        nixpkgs.lib.nixosSystem {
          system = guestSystem;
          specialArgs = {
            inherit inputs;
            vmName = "smoke";
            vmSpec = spec;
          };
          modules = [
            microvm.nixosModules.microvm
            self.nixosModules.microvmGuest
          ];
        };

      # Force both the system closure and the hypervisor runner to evaluate; discard context so the
      # check builds on the host without building the aarch64-linux closure.
      guestDrvs =
        g:
        map builtins.unsafeDiscardStringContext [
          g.config.system.build.toplevel.drvPath
          g.config.microvm.declaredRunner.drvPath
        ];

      # Coverage: host-store + ephemeral (default), per-VM EROFS + persistent, tmpfs home, and the
      # vfkit runner (needs matching aarch64 guest + darwin vmHostPackages, set inside guest.nix).
      variants = [
        (mkGuest "aarch64-linux" (mkSpec { }))
        (mkGuest "aarch64-linux" (mkSpec {
          storeBacking = "image";
          persistent = true;
        }))
        (mkGuest "aarch64-linux" (mkSpec {
          homeBacking = "tmpfs";
        }))
        (mkGuest "aarch64-linux" (mkSpec {
          hypervisor = "vfkit";
        }))
      ];

      # Instantiate a minimal NixOS host that includes the microvms module, to extract the
      # host-side `vm` helper (nix-vm) for black-box CLI tests without a consumer flake.
      # Linux-only (nixosSystem); on Linux the darwin-only builder helper is absent, so the
      # `vm builder` macOS-only gate is exercised too.
      vmHelperFor =
        hostSys:
        let
          host = nixpkgs.lib.nixosSystem {
            system = hostSys;
            specialArgs = { inherit inputs; };
            modules = [
              home-manager.nixosModules.home-manager
              self.nixosModules.options
              self.nixosModules.microvms
              {
                custom.username = "tester";
                custom.microvms.smoke.vsockPort = 9999;
              }
            ];
          };
        in
        lib.findFirst (p: (p.name or "") == "nix-vm")
          (throw "nix-vm helper not found in environment.systemPackages")
          host.config.environment.systemPackages;

      checkSystems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      selfChecks = lib.genAttrs checkSystems (
        hostSys:
        let
          pkgs = nixpkgs.legacyPackages.${hostSys};
          drvs = lib.concatMap guestDrvs variants;
        in
        {
          microvm-guest-eval = pkgs.runCommand "microvm-guest-eval" { } ''
            printf '%s\n' ${lib.escapeShellArgs drvs} > "$out"
          '';
        }
        # The PTY-driven console suite and the host-eval CLI suite are Linux-only: they need a
        # working /dev/ptmx and process tools inside the build sandbox. The GitHub macOS runner's
        # Nix sandbox denies PTY allocation (the suite hangs there), while Linux provides it — and
        # the console driver logic is OS-agnostic, so Linux coverage guards it fully.
        // lib.optionalAttrs (hostSys == "x86_64-linux") {
          # Behavioral regression suite for the `vm run` console driver (echo race, teardown,
          # exit-code propagation, stdout/stderr merge, fatal-boot detection) — drives the real
          # driver against fake PTY runners, no VM needed. See tests/console-run-suite.sh.
          vm-console-run =
            pkgs.runCommand "vm-console-run"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                ];
              }
              ''
                bash ${./tests/console-run-suite.sh} ${./modules/microvms/vm-console-run.py}
                touch "$out"
              '';

          # Black-box CLI dispatch tests for the `vm` helper (usage, unknown cmd, list,
          # doctor-skips-not-running, builder macOS-only gate). See tests/nix-vm-cli-suite.sh.
          vm-cli =
            pkgs.runCommand "vm-cli"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.procps
                ];
              }
              ''
                bash ${./tests/nix-vm-cli-suite.sh} ${vmHelperFor "x86_64-linux"}/bin/nix-vm
                touch "$out"
              '';
        }
      );
    in
    moduleOutputs
    // {
      checks = selfChecks;
      # `nix fmt` — format all .nix files (nixfmt itself doesn't recurse; wrap it with find).
      formatter = lib.genAttrs checkSystems (
        s:
        let
          pkgs = nixpkgs.legacyPackages.${s};
        in
        pkgs.writeShellScriptBin "fmt" ''
          set -eu
          [ "$#" -eq 0 ] && set -- .
          ${pkgs.findutils}/bin/find "$@" -name '*.nix' -not -path '*/.git/*' \
            -exec ${pkgs.nixfmt}/bin/nixfmt {} +
        ''
      );
    };
}
