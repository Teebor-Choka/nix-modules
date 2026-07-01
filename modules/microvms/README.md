# Development microVMs

Sandboxed NixOS environments running via [microvm.nix](https://github.com/microvm-nix/microvm.nix)
with vfkit (Apple Virtualization.framework) on macOS or QEMU/KVM on Linux.

Key properties:
- Persistent `/home` and Nix store overlay (changes survive reboots)
- virtiofs share: `~/work/<vm-name>` on host → `~/work` in VM (always present)
- Optional per-VM extra virtiofs shares (`extraShares`, read-write, opt-in)
- KeePassXC SSH agent forwarded over virtio-vsock — no private keys stored in the VM
- Full home-manager user layer (same as the host, darwin-only items no-op on Linux)

---

## Prerequisites

1. **Config applied:** `rebuild-me` (or `sudo darwin-rebuild switch --flake <dir>#<host>`)
2. **KeePassXC unlocked** with its SSH agent enabled
3. **linux-builder running** (macOS only): `builder up`

---

## Usage

```bash
vm up   <name>   # start VM + bridge KeePassXC agent
vm down <name>   # tear down agent bridge (poweroff inside VM to stop it)
vm list          # show defined VMs and bridge status
```

`vm up`:
1. Creates a socat bridge from `$SSH_AUTH_SOCK` → `~/.local/state/microvm/<name>/agent.sock`
2. Runs `nix run <flakeDir>#microvm-<name>` (foreground serial console)

Type `poweroff` inside the VM to stop it; the agent bridge tears down automatically on exit.

---

## Defining a VM

Add a `custom.microvms.<name>` entry in your host's module list (inline in `flake.nix`
or a separate file):

```nix
{ custom.microvms.myvm = {
    vsockPort      = 1026;   # unique across all VMs on all hosts
    extraHmModules = [ ./users/<user>/home.nix ];
    extraShares    = [{ source = "/Users/<user>/Projects"; mountPoint = "/home/<user>/Projects"; }];
    # sshConfig, sshPubKeys — optional, for per-VM SSH host aliases
}; }
```

Then rebuild the host and build the guest:
```bash
rebuild-me
nix build <flakeDir>#packages.<system>.microvm-myvm
vm up myvm
```

---

## State locations

| Path | Contents |
|------|----------|
| `~/.local/state/microvm/<name>/home.img` | Persistent `/home` volume |
| `~/.local/state/microvm/<name>/store.img` | Nix store overlay |
| `~/.local/state/microvm/<name>/agent.sock` | KeePassXC agent socket (vfkit) |
| `~/work/<name>/` | Host side of the default work virtiofs share |

Reset a VM (wipes all logins and state):
```bash
vm down <name>
rm -rf ~/.local/state/microvm/<name>
```

---

## Option reference (`custom.microvms.<name>`)

| Option | Default | Description |
|--------|---------|-------------|
| `vsockPort` | *(required)* | Unique virtio-vsock port for KeePassXC agent bridge |
| `vcpu` | `12` | Virtual CPU count |
| `mem` | `10240` | RAM in MiB |
| `homeSize` | `20480` | `/home` volume size in MiB |
| `storeSize` | `20480` | Nix store overlay size in MiB |
| `user` | `custom.username` | Guest username |
| `timeZone` | `Europe/Zurich` | Guest timezone |
| `locale` | `en_US.UTF-8` | Guest locale |
| `workDir` | `~/work/<name>` | Host path for the default virtiofs share |
| `hmModules` | `[home-manager/home.nix]` | Base home-manager modules |
| `extraHmModules` | `[]` | Per-VM extra HM modules (user layer, dotfiles, …) |
| `extraShares` | `[]` | Additional virtiofs shares `[{ source, mountPoint }]` |
| `sshConfig` | `""` | Extra `~/.ssh/config` host alias blocks |
| `sshPubKeys` | `{}` | Public key files to place in `~/.ssh/` |
| `vfkitExtraArgs` | `[]` | Extra vfkit CLI arguments |
| `extraModules` | `[]` | Extra NixOS modules |
| `autologin` | `true` | Auto-login on serial console |
| `hypervisor` | `vfkit`/`qemu` | Auto-detected from host platform |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ssh-add -l` empty in VM | Unlock KeePassXC, enable its SSH agent; check `$SSH_AUTH_SOCK` on host |
| Agent bridge not starting | Check `vm list`; ensure `socat` is on PATH |
| No network in VM | Check vfkit/QEMU NAT; `ip a` inside VM |
| Clock wrong after host sleep | chrony `makestep 1 -1` corrects it in seconds; or `chronyc makestep` inside VM |
| First build slow | Normal — cross-compiling guest closure; subsequent builds hit the store overlay |
| `nix build --system aarch64-linux` hangs | linux-builder may be starting; wait ~30 s; `builder status` |
