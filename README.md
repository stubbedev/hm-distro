# hm-distro

home-manager modules for running standalone home-manager on a non-NixOS
distro (Ubuntu, Debian, Fedora, Arch, openSUSE, …). Two things that NixOS gives
you for free and a foreign distro does not:

1. **Privileged installs at activation time.** Some config has to live outside
   `$HOME`: udev rules, polkit rules, PAM services, systemd system units,
   AppArmor profiles, host packages. `distro.privileged.<name>` runs such a step
   through `sudo` during `home-manager switch`, with a banner explaining what
   it is about to do, and skips it on every later switch until its script or
   inputs change.
2. **GL/Vulkan for Nix programs.** A Nix-built GUI program on a foreign distro
   finds neither the host's GPU driver nor a usable Mesa. `distro.gfx.*` wraps
   programs so they do: NVIDIA through glvnd and the host's own driver
   libraries, everything else through nixGLIntel.

Both degrade to no-ops when the same modules are evaluated by home-manager
inside NixOS, nix-darwin or nix-on-droid, so one module set can serve every
host.

## Quick start

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hm-distro = {
      url = "github:stubbedev/hm-distro";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { nixpkgs, home-manager, hm-distro, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        hm-distro.homeManagerModules.default
        ({ config, pkgs, ... }: {
          home.packages = [ (config.distro.gfx.wrap pkgs.alacritty) ];

          distro.privileged.ddcci = {
            body = "Lets the user drive monitor brightness over DDC/CI.";
            script = config.lib.distro.text {
              name = "45-ddcutil-i2c.rules";
              target = "/etc/udev/rules.d/45-ddcutil-i2c.rules";
              text = ''KERNEL=="i2c-[0-9]*", TAG+="uaccess"'';
            } + config.lib.distro.reloadUdev;
          };
        })
      ];
    };
  };
}
```

No overlay is needed: the gfx module brings its own pinned nixGL and builds it
against your `pkgs` only when a mesa wrapper is actually used.

## Modules

| Output                                  | Contents                       |
| --------------------------------------- | ------------------------------ |
| `homeManagerModules.default`            | both of the below              |
| `homeManagerModules.privileged`         | `distro.privileged`, `lib.distro` |
| `homeManagerModules.gfx`                | `distro.gpu`, `distro.gfx`     |

## Options

### `distro.enable`

`bool`, default `!config.submoduleSupport.enable`.

Whether this configuration runs on a foreign distro. home-manager sets
`submoduleSupport.enable` when it is evaluated as a NixOS, nix-darwin or
nix-on-droid submodule (nix-on-droid's bridge sets it too), so the default is
`true` exactly for standalone home-manager. When `false`:

- no privileged step is rendered into `home.activation`;
- `gfx.wrap` / `gfx.wrapExe` return the package unchanged, `gfx.bundle` only
  applies its `flags`/`env`/… wrapping, and `gfx.withDriverLibs` suffixes
  `LD_LIBRARY_PATH` with `/run/opengl-driver/lib` (where NixOS keeps the
  driver libraries).

### `distro.privileged.<name>`

Attribute set of steps. `<name>` is the `home.activation` DAG node name.

| Option        | Type             | Default             | Meaning |
| ------------- | ---------------- | ------------------- | ------- |
| `enable`      | bool             | `true`              | Whether to run this step. |
| `script`      | lines            | —                   | Shell to run. Runs under `set -euo pipefail` and is shellchecked at build time. Must be idempotent. |
| `after`       | list of str      | `[ ]`               | Extra DAG nodes to run after (always after `writeBoundary`). |
| `title`       | str              | `"Installing <name>"` | Banner before the sudo prompt. |
| `body`        | lines            | `""`                | What the step does and why, shown under the banner. |
| `preCheck`    | lines            | `""`                | Guard run before the banner; `exit 0` skips the step silently. |
| `stateInputs` | list of str      | `[ ]`               | Paths whose *existence* is part of the step's input. |

Each step runs as its own script that:

1. puts `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` in front
   of the stripped activation `PATH`, so `sudo` and host tools resolve;
2. sends its output to `/dev/tty` when there is one, so the sudo prompt is
   visible even when activation output is captured;
3. fails if `sudo` is missing;
4. computes `sha256(script) : sha256(existence of each stateInput)` and exits
   immediately if it matches the lock file
   `${config.xdg.stateHome}/hm-distro/<name>.sum`;
5. runs `preCheck`, prints the banner and `body`, runs `script`, and only then
   atomically writes the lock.

A step therefore runs on the first switch, again whenever its script text
changes (which includes every store path it references) or a `stateInputs`
path appears or disappears, and never otherwise. **To force a re-run, delete
its `.sum` file** (or the whole `~/.local/state/hm-distro` directory). A failed
step writes no lock and is retried on the next switch. Steps respect
home-manager's dry-run mode.

### `distro.gpu`

`"auto" | "mesa" | "nvidia"`, default `"auto"`. The host's display driver
stack.

Pure evaluation cannot see the hardware, so `auto` decides at launch instead:
every wrapped program becomes a small dispatcher that takes the `nvidia` path
while the proprietary kernel module is loaded (`/proc/driver/nvidia/version`
exists) and the `mesa` path otherwise. Installing or removing the NVIDIA
driver needs no rebuild. The cost is closure size: both paths are built, so
nixGLIntel and its Mesa ship even on NVIDIA machines.

Set it explicitly to drop the unused path, or on hybrid-graphics laptops
(Intel display, NVIDIA for offload), where the `nvidia` module is loaded but
`mesa` is the right default: `auto` would pick `nvidia` there.

### `distro.gfx`

Read-only functions; use them where you would use the package.

| Function | Signature | Result |
| -------- | --------- | ------ |
| `wrap` | `pkg -> drv` | `pkg`'s `mainProgram` wrapped for GL, same binary name. Only `bin/` is emitted; use `bundle` to keep `share/` (desktop files, man pages). |
| `wrapExe` | `exeName -> pkg -> drv` | One named binary of `pkg` wrapped for GL. |
| `withDriverLibs` | `pkg -> drv` | Lets a non-GL tool `dlopen` vendor libraries by soname (e.g. `btop` loading `libnvidia-ml.so`). Not a no-op when `distro.enable = false`. |
| `bundle` | `attrs -> drv` | Wraps selected binaries and `symlinkJoin`s them over the upstream package. |

`bundle` arguments:

| Argument          | Default                 | Meaning |
| ----------------- | ----------------------- | ------- |
| `pkg`             | —                       | The package. |
| `exes`            | `[ mainProgram ]`       | Binaries to wrap; the first becomes `meta.mainProgram`. |
| `gfx`             | `true`                  | GL-wrap them. `false` to only apply the options below. |
| `vulkan`          | `false`                 | Also set up Vulkan (WebGPU, mpv `--gpu-api=vulkan`, …). |
| `flags`           | `[ ]`                   | `makeWrapper --add-flags`, one per element. |
| `env`             | `{ }`                   | `--set NAME value`. |
| `unset`           | `[ ]`                   | `--unset NAME`. |
| `prefix`          | `{ }`                   | `--prefix NAME : value`. |
| `run`             | `[ ]`                   | `--run command`. |
| `includeUpstream` | `true`                  | Join the rest of `pkg` (`share/`, other binaries) underneath. |

```nix
config.distro.gfx.bundle {
  pkg = pkgs.google-chrome;
  vulkan = true;
  flags = [ "--enable-features=Vulkan" ];
  env.GTK_USE_PORTAL = "1";
}
```

## Helpers: `config.lib.distro`

Shell fragments for `distro.privileged.<name>.script` (and `preCheck`). They
return strings, so concatenate or interpolate them.

| Helper | Signature | Emits |
| ------ | --------- | ----- |
| `file` | `{ source, target, mode ? "0644", owner ? "root", group ? "root" }` | `sudo install -D` of a store path to `target`. |
| `text` | `{ name, text, target, mode?, owner?, group? }` | `file` from inline text (`pkgs.writeText name text`). |
| `link` | `{ source, target }` | Creates the parent directory and `sudo ln -sfT`. |
| `polkitRule` | `{ source, target }` | `file`, then `chown root:polkitd` where that group exists. polkitd watches its rules directories, so no restart. |
| `hostPackage` | `{ detect ? null, have ? "command -v <detect>", apt, dnf, pacman }` | Installs host packages with whichever of apt-get / dnf / pacman exists, unless `have` (a shell test) already succeeds. Pass `detect` (a command name) or `have`. Fails on any other package manager. |
| `reloadUnits` | string | `systemctl daemon-reload`, if systemd is present. |
| `reloadUdev` | string | `udevadm control --reload-rules`, if udev is present. |
| `requireCommand` | `cmd -> string` | `preCheck` guard: skip the step unless `cmd` is on PATH. |
| `requirePath` | `path -> string` | `preCheck` guard: skip the step unless `path` exists. |
| `apparmor` | `{ appName, profileName, programGlob }` | A complete step attrset (assign it to `distro.privileged.<name>`). |

### AppArmor on Ubuntu 24.04+

Ubuntu 24.04 and later only grant unprivileged user namespaces, and clean
profile transitions, to binaries covered by a named AppArmor profile.
Nix-store paths match none of the stock profiles, so a Nix-installed Chromium,
Electron app or bubblewrap runs as "unprivileged unconfined" and aborts with
`No usable sandbox!`; runc's `docker-default` gets stacked into
`docker-default//&unconfined`. `apparmor` installs a named but otherwise
unconfined profile for the given store glob and loads it. It skips itself on
hosts without `apparmor_status`.

```nix
distro.privileged.chromeApparmor = config.lib.distro.apparmor {
  appName = "Chrome";
  profileName = "nix-chrome";
  programGlob = "/nix/store/*-google-chrome-*/share/google/chrome/{chrome,chrome-sandbox}";
};
```

## How the GL wrapping works

### NVIDIA: glvnd against the host driver

The program's own glvnd (linked from nixpkgs) is pointed at the NVIDIA vendor
libraries **the distro driver package installed**:

- `__GLX_VENDOR_LIBRARY_NAME=nvidia` and
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json`;
- `LD_LIBRARY_PATH` gains the host driver directories;
- `__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES` lists the host's
  `/usr/share/egl/egl_external_platform.d` first (driver-matched), then
  nixpkgs' `egl-wayland` and `egl-gbm` descriptors as fallback;
- `GBM_BACKENDS_PATH` / `LIBGL_DRIVERS_PATH` cover every distro layout;
- with `vulkan = true`, `VK_ADD_DRIVER_FILES` adds the host `nvidia_icd.json`.

No driver version appears anywhere: the libraries *are* the driver package's
files, so they always match the running kernel module and follow driver
updates on their own. nixGL's NVIDIA wrapper, by contrast, has to bundle a
userspace of the exact same version as the kernel module and breaks on every
driver update (and on its version-detection regex).

Every variable is `--suffix`ed, so values you set yourself win. Missing
directories are skipped by the loaders; the lists are long because if *none*
of them exists, EGL/GBM initialisation fails. Layouts checked against the
distro package file lists (October 2026), with `<multiarch>` being
`/usr/lib/<cpu>-linux-gnu`:

| Distro | Package | Vendor libs | GBM backend |
| ------ | ------- | ----------- | ----------- |
| Arch | `nvidia-utils` | `/usr/lib` | `/usr/lib/gbm` |
| Ubuntu | `libnvidia-gl-<flavour>` | `<multiarch>` | `<multiarch>/gbm` |
| Debian (trixie) | `libnvidia-*` (alternatives layout) | `<multiarch>/nvidia/current` | `<multiarch>/nvidia/current` |
| Fedora / RHEL | `xorg-x11-drv-nvidia-libs` | `/usr/lib64` | `/usr/lib64/gbm` |
| openSUSE | NVIDIA G06 driver packages | `/usr/lib64/nvidia` | — |

`/run/opengl-driver{,-32}` entries are included too, so the same wrapper also
works on a NixOS host.

### Mesa: nixGLIntel

Everything else runs under nixGL's `nixGLIntel` (Mesa from nixpkgs, despite
the name it covers Intel, AMD and other Mesa drivers), plus `nixVulkanIntel`
when `vulkan = true`. nixGL is a pinned input of this flake, built against
your `pkgs` with 32-bit support on x86_64.

## Limitations

- `hostPackage` knows apt-get, dnf and pacman only.
- Steps need an interactive `sudo` (or passwordless sudo) at switch time; in a
  non-interactive switch without a TTY, sudo's own prompt rules apply.
- Removing a step does not undo what it installed. Delete the files yourself.
- The lock records only path *existence* for `stateInputs`, not contents.
- `auto` keys on the NVIDIA kernel module alone; hybrid-graphics machines
  should set `distro.gpu = "mesa"` and offload explicitly.

## Development

```sh
nix flake check   # builds example configurations for auto, mesa, nvidia and disabled
nix fmt
```

## License

MIT
