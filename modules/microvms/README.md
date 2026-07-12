# Development microVMs

Sandboxed NixOS environments running via [microvm.nix](https://github.com/microvm-nix/microvm.nix)
with vfkit (Apple Virtualization.framework) on macOS or QEMU/KVM on Linux.

Key properties:
- **Non-persistent by default**, with **concurrent instances**: each `vm up` runs in its own working
  dir (relative volume/socket paths), so many instances of the same VM can run at once and are wiped
  on exit. Opt into a persistent, single-instance VM with `persistent = true`.
- **Read-only store base** shared across instances: the host `/nix/store` via virtiofs (`storeBacking =
  "host"`, default — no per-VM store build) or a per-VM EROFS image (`storeBacking = "image"`).
- **Optional forwarded SSH agent** over virtio-vsock (`forwardSshAgent`, default on) — tool-agnostic,
  forwards the host's `$SSH_AUTH_SOCK`; no private keys stored in the VM.
- Optional per-VM virtiofs shares (`extraShares`, read-write, opt-in).
- Full home-manager user layer (darwin-only items no-op on Linux).

This is a generic base: consumer-specific packages, overlays, and secret/mount mechanisms are injected
per VM via `extraModules`, `overlays`, `hostPreLaunch`, etc. — the module imposes none of them.

---

## Consumer contract

These modules are input-free; the consuming flake passes its own inputs via `specialArgs`:

- `nixModules.microvms` (host module) — declares the `custom.microvms` options + the `vm` helper.
- `nixosModules.microvmGuest` (guest module) — instantiated per VM as:
  ```nix
  nixpkgs.lib.nixosSystem {
    system = "<guest-linux-system>";
    specialArgs = { inherit inputs; vmName = "<name>"; vmSpec = <evaluated custom.microvms.<name>>; };
    modules = [ inputs.microvm.nixosModules.microvm nix-modules.nixosModules.microvmGuest ] ++ vmSpec.extraModules;
  };
  ```
  `inputs` must provide **`nixpkgs`**, **`home-manager`**, and **`microvm`**.

---

## Usage

```bash
vm up    <name>          # start VM (forwards the host SSH agent, attaches serial console)
vm test  <name> [secs]   # headless smoke-test: boot to multi-user then tear down (exit 0 = pass)
vm down  <name>          # tear down agent bridge (poweroff inside the VM to stop it)
vm list                  # show defined VMs
vm build <name>          # pre-build the guest image
```

`vm up` runs in the foreground (serial console). Type `poweroff` inside to stop; ephemeral state is
wiped on exit. Run `vm up <name>` in several terminals for concurrent instances.

---

## Defining a VM

```nix
{ custom.microvms.myvm = {
    vsockPort   = 1026;            # required while forwardSshAgent = true; unique across all VMs
    persistent  = false;          # ephemeral+concurrent (default) or persistent single-instance
    extraShares = [{ source = "/Users/<user>/Projects"; mountPoint = "/home/<user>/Projects"; }];
    extraModules   = [ ./my-guest-extras.nix ];   # consumer packages/overlays/services
    extraHmModules = [ ./home.nix ];              # per-user home-manager layer
}; }
```

---

## State locations

Per-instance (ephemeral): `~/.local/state/microvm/<name>/run.<pid>.<rand>/` holds `home.img`,
`agent.sock`, and any `hostPreLaunch` artifacts — wiped on exit. Persistent VMs keep `home.img` +
`store.img` at `~/.local/state/microvm/<name>/`.

---

## Option reference (`custom.microvms.<name>`)

| Option | Default | Description |
|--------|---------|-------------|
| `hypervisor` | `vfkit`/`qemu` | Auto-detected from host platform |
| `vcpu` | `12` | Virtual CPU count |
| `mem` | `10240` | RAM in MiB |
| `homeSize` | `10240` | `/home` size in MiB |
| `storeSize` | `20480` | Writable store overlay size in MiB (persistent mode) |
| `persistent` | `false` | Ephemeral+concurrent vs persistent single-instance (lock-guarded) |
| `homeBacking` | `auto` | `tmpfs` / `disk` / `auto` (tmpfs when `mem > 2*homeSize`) |
| `storeBacking` | `host` | `host` = share host `/nix/store` (ro, fast); `image` = per-VM EROFS |
| `forwardSshAgent` | `true` | Forward the host `$SSH_AUTH_SOCK` over virtio-vsock |
| `vsockPort` | `null` | vsock port for the forwarded agent (required when `forwardSshAgent`) |
| `user` | `custom.username` | Guest username |
| `timeZone` | `Europe/Zurich` | Guest timezone (via `custom.microvmDefaults`) |
| `locale` | `en_US.UTF-8` | Guest locale |
| `autologin` | `true` | Auto-login on serial console |
| `mac` | *(derived)* | Guest NIC MAC (auto from name) |
| `overlays` | `[]` | nixpkgs overlays applied in the guest |
| `allowUnfree` | `false` | `allowUnfree` inside the guest |
| `nameservers` | `["1.1.1.1" "8.8.8.8"]` | Guest DNS |
| `substituters` | *(cache.nixos.org + nix-community)* | Guest binary caches |
| `trustedPublicKeys` | *(matching keys)* | Guest cache public keys |
| `hmModules` | `[home-manager/home.nix]` | Base home-manager modules |
| `extraHmModules` | `[]` | Per-VM home-manager layer |
| `extraShares` | `[]` | Virtiofs shares `[{ source, mountPoint, tag? }]` |
| `sshConfig` | `""` | Extra `~/.ssh/config` blocks |
| `sshPubKeys` | `{}` | Public key files placed in `~/.ssh/` |
| `vfkitExtraArgs` | `[]` | Extra vfkit CLI arguments |
| `extraModules` | `[]` | Extra guest NixOS modules (packages, overlays, services) |
| `hostPreLaunch` | `""` | Host shell run in the instance dir before launch (secret/mount hooks) |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ssh-add -l` empty in VM | Ensure an SSH agent runs on the host (`$SSH_AUTH_SOCK` set); `forwardSshAgent = true` |
| `vm up` exits immediately | A `hostPreLaunch` hook failed — hooks should be non-fatal; check its output |
| `/home` never mounts (`vmhome`/dep failed) | Disk-mode home image wasn't attached; on vfkit ensure you launched via `vm up` |
| No network in VM | Check vfkit/QEMU NAT; `ip a` inside VM |
| Clock wrong after host sleep | chrony `makestep 1 -1` corrects it in seconds; or `chronyc makestep` inside VM |
| First build slow | Normal — building the guest closure on the linux-builder; later boots reuse the store |
