# nix-modules

Reusable nix-darwin + NixOS + home-manager modules.

Opinionated but broadly applicable: microVM dev sandboxes (vfkit on macOS, QEMU on Linux),
a vfkit linux-builder for aarch64-linux cross-compilation, a shared shell/font/direnv base,
and a generic home-manager starter. Personal values (username, Homebrew lists, dotfiles, host
registry) live in the consuming private repository.

---

## Module outputs

| Output | Description |
|--------|-------------|
| `homeManagerModules.default` | Generic home-manager base (coreutils, htop, zsh/bash) |
| `darwinModules.default` | macOS host module (Homebrew, TouchID sudo, Spotlight alias) |
| `nixosModules.core` | NixOS workstation base (systemd-boot, NetworkManager, pipewire) |
| `nixosModules.gnome` | GNOME/Wayland desktop via GDM |
| `nixosModules.microvmGuest` | Shared NixOS guest base for dev microVMs |
| `nixosModules.builderGuest` | Minimal NixOS guest for the vfkit linux-builder |
| `nixModules.options` | `custom.*` option declarations |
| `nixModules.nativeNix` | Nix daemon settings (caches, GC, optimise) |
| `nixModules.shared` | Cross-platform base (overlays, zsh, direnv, GPG, fonts, HM wiring) |
| `nixModules.microvms` | Host-side microVM module (option schema + `vm`/`builder` helpers) |

---

## How to consume

### 1. Add the flake input

```nix
# flake.nix (private host repo)
inputs = {
  nixpkgs.url        = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";  # or nixos-YY.MM
  nix-darwin.url     = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
  nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  home-manager.url   = "github:nix-community/home-manager/release-26.05";
  home-manager.inputs.nixpkgs.follows = "nixpkgs";
  nix-homebrew.url   = "github:zhaofengli-wip/nix-homebrew";
  nixneovimplugins.url = "github:NixNeovim/nixpkgs-vim-extra-plugins";
  nixneovimplugins.inputs.nixpkgs.follows = "nixpkgs";
  microvm.url        = "github:microvm-nix/microvm.nix";
  microvm.inputs.nixpkgs.follows = "nixpkgs";

  # This repo
  nix-modules.url    = "github:Teebor-Choka/nix-modules";
};
```

> `nix-modules` declares **no inputs** — no `follows` wiring is needed. The consuming flake's own
> inputs are passed to the modules via `specialArgs.inputs`.

### 2. Wire the modules

The modules expect `specialArgs = { inherit inputs hostname; }` so they can access `inputs.nixpkgs`,
`inputs.home-manager`, `inputs.microvm`, `inputs.nixneovimplugins`, and `inputs.nix-homebrew` at
evaluation time.

```nix
# Minimal darwin host
nix-darwin.lib.darwinSystem {
  system = "aarch64-darwin";
  specialArgs = { inherit inputs; hostname = "my-mac"; };
  modules = [
    inputs.nix-modules.nixModules.options
    inputs.nix-modules.nixModules.nativeNix
    inputs.nix-modules.nixModules.shared
    inputs.nix-modules.nixModules.microvms
    inputs.nix-modules.darwinModules.default
    nix-homebrew.darwinModules.nix-homebrew
    home-manager.darwinModules.home-manager
    ./users/<username>              # sets custom.username, homebrew lists, wires home-manager
    { custom.nativeNix = true;
      custom.flakeDir  = "/path/to/your/flake"; }
  ];
}

# Minimal NixOS workstation
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit inputs; hostname = "my-workstation"; };
  modules = [
    inputs.nix-modules.nixModules.options
    inputs.nix-modules.nixModules.nativeNix
    inputs.nix-modules.nixModules.shared
    inputs.nix-modules.nixModules.microvms
    inputs.nix-modules.nixosModules.core
    inputs.nix-modules.nixosModules.gnome
    home-manager.nixosModules.home-manager
    ./hosts/my-workstation/hardware-configuration.nix
    ./users/<username>
    { custom.nativeNix = true;
      custom.flakeDir  = "/path/to/your/flake"; }
  ];
}
```

### 3. User module (`users/<username>/default.nix`)

The `custom.username` option has no default — you **must** set it. The minimal user module:

```nix
# users/<username>/default.nix
{ ... }: {
  custom = {
    username = "<username>";
    flakeDir = "/home/<username>/.config/nix";   # path to your private repo

    homebrew = {                               # darwin only; leave empty on NixOS
      taps  = [];
      brews = [];
      casks = [];
      masApps = {};
    };
  };

  home-manager.users."<username>" = import ./home.nix;  # your personal HM config
}
```

---

## `custom.*` option surface

Declared in `modules/options.nix` and `modules/microvms/default.nix`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `custom.username` | `str` | *(required)* | Primary user on this host |
| `custom.hostname` | `str` | `""` | Hostname (informational; set via `networking.hostName`) |
| `custom.nativeNix` | `bool` | `false` | Enable Nix daemon tuning, GC, remote builder |
| `custom.flakeDir` | `str` | `~/…/.config/nix` | Absolute path to your host flake (for `rebuild-me` and VM helpers) |
| `custom.homebrew.taps` | `[str]` | `[]` | Homebrew taps (darwin) |
| `custom.homebrew.brews` | `[str]` | `[]` | Homebrew formulae |
| `custom.homebrew.casks` | `[str]` | `[]` | Homebrew casks |
| `custom.homebrew.masApps` | `{str→int}` | `{}` | Mac App Store apps (name → ID) |
| `custom.microvmDefaults.timeZone` | `str` | `"Europe/Zurich"` | Default VM timezone |
| `custom.microvmDefaults.locale` | `str` | `"en_US.UTF-8"` | Default VM locale |
| `custom.microvms.<name>.*` | submodule | — | See [microVM option reference](modules/microvms/README.md) |

---

## Layout

```
flake.nix                   Module outputs (no inputs)
modules/
  options.nix               custom.* option declarations
  native-nix.nix            Nix daemon settings (caches, GC, optimise)
  shared/                   Cross-platform: overlays, zsh, direnv, GPG, fonts, HM wiring
  darwin/
    core.nix                macOS: Homebrew, TouchID sudo, Spotlight alias, zsh extras
  nixos/
    core.nix                NixOS workstation base (systemd-boot, NetworkManager, pipewire)
    desktop/gnome.nix       GNOME/Wayland via GDM
  microvms/
    default.nix             custom.microvms option schema + vm/builder shell helpers
    guest.nix               Shared NixOS guest base (virtiofs, home-manager, vsock bridge)
    README.md               microVM option reference and usage
  builder/
    guest.nix               Minimal NixOS guest for the vfkit linux-builder
home-manager/
  home.nix                  Generic base: coreutils, htop, zsh/bash enable
```

---

## Updating

Pin is managed by `flake.lock` in the consuming repo:

```bash
nix flake update nix-modules   # bump to latest commit on main
nix flake update               # bump all inputs
```

### Local development

To iterate on these modules without pushing:

```bash
# In your private repo:
nix eval .#darwinConfigurations.<host>.config.system.build.toplevel \
  --apply lib.isDerivation \
  --override-input nix-modules path:../nix-modules
```

---

## Features

### Dev microVMs

Lightweight NixOS VMs on vfkit (macOS) or QEMU/KVM (Linux). See
[modules/microvms/README.md](modules/microvms/README.md) for the full option reference.

Quick definition (inline in your `flake.nix`):

```nix
{ custom.microvms.myvm = {
    vsockPort      = 1024;         # unique per VM per host
    extraHmModules = [ ./users/<user>/home.nix ];
    extraShares    = [{ source = "/path/on/host"; mountPoint = "/path/in/guest"; }];
}; }
```

```bash
vm up   myvm   # start + bridge KeePassXC agent
vm down myvm   # tear down bridge
vm list        # status
```

### linux-builder (macOS)

Minimal aarch64-linux NixOS VM via Apple Virtualization.framework. Enables cross-building
aarch64-linux derivations from a darwin host without QEMU.

```bash
builder up       # start (auto-bootstraps on first run via Apple Container, ~5–10 min)
builder down     # stop
builder status   # running? SSH reachable?
builder logs     # tail console output
```

### Shared base

Every host (darwin or NixOS) gets via `nixModules.shared`:
- nixneovimplugins overlay + `allowUnfree`
- zsh (completion, direnv hook, `~/.local/bin` on PATH) + bash
- direnv + nix-direnv
- GPG agent
- Iosevka, Roboto, Source Code Pro fonts
- home-manager wiring (`useGlobalPkgs`, `useUserPackages`)

### macOS specifics (`darwinModules.default`)

- Homebrew integration via nix-homebrew (`custom.homebrew.*`)
- TouchID for sudo (`security.pam.services.sudo_local.touchIdAuth`)
- Spotlight indexing of Nix `.app` bundles
- `rebuild-me` alias → `sudo darwin-rebuild switch --flake <custom.flakeDir>`

### NixOS specifics (`nixosModules.core`)

- systemd-boot (UEFI)
- NetworkManager
- Pipewire (ALSA + PulseAudio compat)
- OpenSSH server
- `rebuild-me` alias → `sudo nixos-rebuild switch --flake <custom.flakeDir>`
