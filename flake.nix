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

      # ── microVM fleet builder (consumer-facing lib helper) ──────────────────────
      # Turns a consumer's host registry into the microVM flake outputs it would otherwise
      # hand-roll: per-VM guest configs, `nix run`-able runner packages, and eval/helper
      # checks. The consumer passes its OWN inputs (must provide nixpkgs + microvm); the
      # nix-modules guest/builder modules are closed over from this flake.
      #
      #   hosts      : the raw host registry ({ <name> = { system; class; …; }; })
      #   builtHosts : the evaluated systems (darwinSystem / nixosSystem) keyed by the same names
      #   includeBuilder : also build the vfkit linux-builder (aarch64-linux) — default true
      #
      # Returns { guestConfigs; builderVm; packages; checks; }.
      mkMicrovmFleet =
        {
          inputs,
          hosts,
          builtHosts,
          includeBuilder ? true,
        }:
        let
          hostNames = lib.attrNames hosts;
          # Darwin hosts cross-build to their NixOS guest system; Linux hosts build natively.
          guestSystemFor = hostSystem: builtins.replaceStrings [ "-darwin" ] [ "-linux" ] hostSystem;

          mkGuest' =
            guestSystem: name: spec:
            inputs.nixpkgs.lib.nixosSystem {
              system = guestSystem;
              specialArgs = {
                inherit inputs;
                vmName = name;
                vmSpec = spec;
              };
              modules = [
                inputs.microvm.nixosModules.microvm
                moduleOutputs.nixosModules.microvmGuest
              ]
              ++ spec.extraModules;
            };

          builderVm = inputs.nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            specialArgs = { inherit inputs; };
            modules = [
              inputs.microvm.nixosModules.microvm
              moduleOutputs.nixosModules.builderGuest
            ];
          };

          # All guest configs across every host (VM names must be globally unique).
          guestConfigs = builtins.foldl' (
            acc: hn:
            let
              guestSys = guestSystemFor hosts.${hn}.system;
              vmSpecs = builtHosts.${hn}.config.custom.microvms;
            in
            acc // lib.mapAttrs (vmName: vmSpec: mkGuest' guestSys vmName vmSpec) vmSpecs
          ) { } hostNames;

          # Runner packages grouped per host system so `nix run .#microvm-<name>` works.
          basePackages = builtins.foldl' (
            acc: hn:
            let
              sys = hosts.${hn}.system;
              vmPkgs = lib.mapAttrs' (
                vmName: _:
                lib.nameValuePair "microvm-${vmName}" guestConfigs.${vmName}.config.microvm.declaredRunner
              ) builtHosts.${hn}.config.custom.microvms;
            in
            acc // { ${sys} = (acc.${sys} or { }) // vmPkgs; }
          ) { } hostNames;

          packages =
            if includeBuilder then
              lib.recursiveUpdate basePackages {
                aarch64-darwin.microvm-linux-builder = builderVm.config.microvm.declaredRunner;
              }
            else
              basePackages;

          # Force full eval + instantiation of every guest toplevel (string context discarded so
          # the check builds on the host without building the aarch64-linux closures).
          mkEvalCheck =
            sys: drvPaths:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${sys};
              lines = lib.concatStringsSep "\n" (map builtins.unsafeDiscardStringContext drvPaths);
            in
            pkgs.runCommand "microvms-eval-check" { } ''
              printf '%s\n' "${lines}" > "$out"
            '';

          evalChecks = builtins.foldl' (
            acc: hn:
            let
              sys = hosts.${hn}.system;
              vmNames = lib.attrNames builtHosts.${hn}.config.custom.microvms;
              guestDrvs' = map (n: guestConfigs.${n}.config.system.build.toplevel.drvPath) vmNames;
              # The vfkit builder is hosted on the darwin control node.
              extraDrvs = lib.optional (
                includeBuilder && sys == "aarch64-darwin"
              ) builderVm.config.system.build.toplevel.drvPath;
              drvPaths = guestDrvs' ++ extraDrvs;
            in
            if drvPaths == [ ] then
              acc
            else
              acc
              // {
                ${sys} = (acc.${sys} or { }) // {
                  microvms-eval = mkEvalCheck sys drvPaths;
                };
              }
          ) { } hostNames;

          # Build the `vm` helper (writeShellScriptBin runs `bash -n`) so a syntax error in the
          # generated wrapper fails `nix flake check` — the guest eval-check can't catch it.
          helperChecks = builtins.foldl' (
            acc: hn:
            let
              sys = hosts.${hn}.system;
              pkgs' = builtHosts.${hn}.config.environment.systemPackages or [ ];
              helper = lib.findFirst (p: (p.name or "") == "nix-vm") null pkgs';
            in
            if hosts.${hn}.class == "darwin" && helper != null then
              acc
              // {
                ${sys} = (acc.${sys} or { }) // {
                  vm-helper = helper;
                };
              }
            else
              acc
          ) { } hostNames;
        in
        {
          inherit guestConfigs builderVm packages;
          checks = lib.recursiveUpdate evalChecks helperChecks;
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
          secrets = [ ];
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
        secretsGuest # secret injection wired (inject-secrets service + injected-secrets share)
      ];

      # ── New-functionality test guests + wiring assertions ───────────────────────
      # Secret injection: a file-target secret exercises the guest inject-secrets service and
      # the auto-added /run/injected-secrets share (host-side staging is checked via `vm-helper`).
      secretsGuest = mkGuest "aarch64-linux" (mkSpec {
        secrets = [
          {
            db = "/tmp/test.kdbx";
            keychainDbPass = "test-svc";
            entry = "Test/Entry";
            attribute = "password";
            target = {
              filePath = ".claude/.credentials.json";
              envName = null;
            };
          }
        ];
      });
      # forwardSshAgent = false ⇒ the ssh-agent-bridge-ready gate must NOT be created.
      noSshGuest = mkGuest "aarch64-linux" (mkSpec {
        forwardSshAgent = false;
      });
      baseGuest = mkGuest "aarch64-linux" (mkSpec { }); # forwardSshAgent = true (default)

      # Throws (failing the check) if any wiring invariant regresses.
      microvmWiringOk =
        let
          conditions = {
            "inject-secrets service present when secrets set" =
              secretsGuest.config.systemd.services ? inject-secrets;
            "injected-secrets share added when secrets set" = lib.any (
              s: s.tag == "injected-secrets"
            ) secretsGuest.config.microvm.shares;
            "ssh-agent-bridge-ready present when forwarding" =
              baseGuest.config.systemd.services ? ssh-agent-bridge-ready;
            "ssh-agent-bridge-ready absent when not forwarding" =
              !(noSshGuest.config.systemd.services ? ssh-agent-bridge-ready);
            "github.com knownHost pre-trusted" = baseGuest.config.programs.ssh.knownHosts ? "github.com";
          };
          failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) conditions);
        in
        if failures == [ ] then
          true
        else
          throw "microvm wiring regressed: ${lib.concatStringsSep "; " failures}";

      # ── mkMicrovmFleet lib helper check ─────────────────────────────────────────
      # Build a sample host with two VMs, run the helper, and assert its outputs.
      fleetHost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          home-manager.nixosModules.home-manager
          self.nixosModules.options
          self.nixosModules.microvms
          {
            custom.username = "tester";
            custom.microvms.alpha.vsockPort = 1024;
            custom.microvms.beta.vsockPort = 1025;
          }
        ];
      };
      fleet = mkMicrovmFleet {
        inherit inputs;
        hosts = {
          testhost = {
            system = "x86_64-linux";
            class = "nixos";
          };
        };
        builtHosts = {
          testhost = fleetHost;
        };
        includeBuilder = false;
      };
      fleetOk =
        let
          conditions = {
            "guestConfigs has alpha" = fleet.guestConfigs ? alpha;
            "guestConfigs has beta" = fleet.guestConfigs ? beta;
            "packages has microvm-alpha" = fleet.packages.x86_64-linux ? "microvm-alpha";
            "packages has microvm-beta" = fleet.packages.x86_64-linux ? "microvm-beta";
            "checks has microvms-eval" = fleet.checks.x86_64-linux ? microvms-eval;
          };
          failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) conditions);
        in
        if failures == [ ] then
          true
        else
          throw "mkMicrovmFleet regressed: ${lib.concatStringsSep "; " failures}";

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

          # Assert the secret-injection + ssh-agent-race wiring invariants (eval-only).
          microvm-wiring = pkgs.runCommand "microvm-wiring" { } (
            assert microvmWiringOk;
            ''
              echo "microvm secret-injection + ssh-agent wiring OK" > "$out"
            ''
          );
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

          # mkMicrovmFleet: assert helper outputs, then build its own eval-check derivation
          # (an x86_64-linux derivation, hence Linux-only here to avoid a cross-system build).
          microvm-fleet-lib =
            assert fleetOk;
            fleet.checks.x86_64-linux.microvms-eval;
        }
      );
    in
    moduleOutputs
    // {
      # Consumer-facing helpers (input-free; callers pass their own inputs).
      lib = {
        inherit mkMicrovmFleet;
      };

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
