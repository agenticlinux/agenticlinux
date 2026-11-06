<p align="center">
  <img src="https://github.com/ericcurtin/agenticlinux/releases/download/assets/agenticlinux-logo-256.png" alt="AgenticLinux logo" width="160">
</p>

<h1 align="center">AgenticLinux</h1>

A Linux desktop built for working with AI agents. Everything is there on
first boot: the `claude`, `codex`, `opencode`, `openclaw` and `goose` agents,
[herdr](https://herdr.dev) to run them side by side,
[CodexBar](https://codex.bar) to keep an eye on their usage limits, the
[ChatGPT](https://learn.chatgpt.com/docs/app) (with Codex),
[OpenCode](https://opencode.ai) and [Goose](https://goose-docs.ai) desktop
apps, Google Chrome,
[llmman](https://github.com/llmmanorg/llmman) to run models locally or connect
any agent to any provider, [Docker Engine](https://docs.docker.com/engine/)
(rootful and [rootless](https://docs.docker.com/engine/security/rootless/)) and
[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) to run agents in
isolation, [QEMU](https://www.qemu.org) with KVM for full virtual machines,
GPU runtimes for Vulkan, ROCm and NVIDIA/CUDA, and a full developer
toolset.

AgenticLinux is a [bootc](https://bootc-dev.github.io/bootc/) image: the whole
OS ships as a container, so updates are atomic and rollback is one command.
It is built from Fedora 45 (or Fedora 44) packages on the
[fedora-ostree-desktops](https://quay.io/organization/fedora-ostree-desktops)
images, or from CentOS Stream 10 packages (with EPEL) on the
[centos-bootc](https://quay.io/repository/centos-bootc/centos-bootc) image,
and available for x86_64 and aarch64.

<p align="center">
  <a href="https://github.com/ericcurtin/ericcurtin.github.io/releases/download/assets/openclaw-web.mp4">
    <img src="https://github.com/ericcurtin/ericcurtin.github.io/releases/download/assets/openclaw-web.webp" alt="OpenClaw's web Control UI on the AgenticLinux KDE desktop, asked to check the machine's health, turn on automatic OS updates and reclaim Docker disk (click for the video)" width="900">
  </a>
</p>

## Quick start

1. Download the ISO for your desktop and architecture from the
   [latest release](https://github.com/ericcurtin/agenticlinux/releases/latest),
   boot it and install as usual.
2. Add yourself to the `docker` group, then log out and back in (or use
   [rootless Docker](#docker) instead):

   ```sh
   sudo usermod -aG docker "$USER"
   ```

3. Run an agent on a local model, or on any hosted provider:

   ```sh
   llmman launch claude --model qwen3.8
   llmman launch opencode --provider openrouter --model qwen/qwen3-coder
   ```

Each variant is an image tag, `docker.io/ericcurtin044/agenticlinux:<tag>`. The
plain desktop name is the default and is Fedora 45. The `fedora45-` and
`fedora44-` tags name the release explicitly: a `fedora44-` tag stays on
Fedora 44 whatever the default becomes. To stay on Fedora 44, switch to its
variant:

```sh
sudo bootc switch docker.io/ericcurtin044/agenticlinux:fedora44-kde
```

| Desktop    | Fedora 45 (the default)     | Fedora 44         |
|------------|-----------------------------|-------------------|
| KDE Plasma | `kde`, `fedora45-kde`       | `fedora44-kde`    |
| GNOME      | `gnome`, `fedora45-gnome`   | `fedora44-gnome`  |
| Sway       | `sway`, `fedora45-sway`     | `fedora44-sway`   |
| COSMIC     | `cosmic`, `fedora45-cosmic` | `fedora44-cosmic` |
| Xfce       | `xfce`, `fedora45-xfce`     | `fedora44-xfce`   |
| Budgie     | `budgie`, `fedora45-budgie` | `fedora44-budgie` |
| no desktop | `base`, `fedora45-base`     | `fedora44-base`   |

CentOS Stream 10, with EPEL, has two desktops and a base image:

| Desktop    | CentOS Stream 10 |
|------------|------------------|
| KDE Plasma | `centos-kde`     |
| GNOME      | `centos-gnome`   |
| no desktop | `centos-base`    |

The `16k-` variants are the Fedora 45 variants with a 16 KiB-page kernel, for Apple
Silicon Macs (see [16k kernels](#16k-kernels)):

| Desktop    | 16k, Fedora 45                      |
|------------|-------------------------------------|
| KDE Plasma | `16k-kde`, `16k-fedora45-kde`       |
| GNOME      | `16k-gnome`, `16k-fedora45-gnome`   |
| Sway       | `16k-sway`, `16k-fedora45-sway`     |
| COSMIC     | `16k-cosmic`, `16k-fedora45-cosmic` |
| Xfce       | `16k-xfce`, `16k-fedora45-xfce`     |
| Budgie     | `16k-budgie`, `16k-fedora45-budgie` |
| no desktop | `16k-base`, `16k-fedora45-base`     |

The `64k-` variants are the same with a 64 KiB-page kernel, for the NVIDIA DGX
Spark and other Arm servers (see [64k kernels](#64k-kernels)):

| Desktop    | 64k, Fedora 45                      |
|------------|-------------------------------------|
| KDE Plasma | `64k-kde`, `64k-fedora45-kde`       |
| GNOME      | `64k-gnome`, `64k-fedora45-gnome`   |
| Sway       | `64k-sway`, `64k-fedora45-sway`     |
| COSMIC     | `64k-cosmic`, `64k-fedora45-cosmic` |
| Xfce       | `64k-xfce`, `64k-fedora45-xfce`     |
| Budgie     | `64k-budgie`, `64k-fedora45-budgie` |
| no desktop | `64k-base`, `64k-fedora45-base`     |

The variants carry the same packages on both distributions, so the list is
what CentOS Stream 10, EPEL 10 and RPM Fusion have: GNOME and KDE Plasma are
the desktops that exist there. CentOS Stream's kernel tracks the next RHEL
10 minor release.

## Signing in to the agents

On a local model, through `llmman launch`, the agents need no account.
Otherwise sign in once per agent:

- `claude`: log in in the browser on first run, or set `ANTHROPIC_API_KEY`.
- `codex`: `codex login`, or `printenv OPENAI_API_KEY | codex login --with-api-key`.
- `opencode`: `/connect` in its TUI.
- `openclaw`: `openclaw onboard`.
- `goose`: `goose configure`.
- `llmman`: export the provider's key (`OPENROUTER_API_KEY`, ...) before
  `llmman launch --provider ...`; `llmman providers` shows which are set.

The ChatGPT app asks you to sign in when it first starts. Credentials stay in
your home directory, which [updates](#updates) leave alone.

## Desktop apps

The desktop apps of the agents that publish an RPM are installed from it,
and start from the applications menu or as `chatgpt`, `opencode-desktop` and
`goose-desktop`:

- **ChatGPT**: OpenAI's one desktop app, which is also the Codex app (the
  "Codex" mode inside it). Its Linux build is a preview.
- **OpenCode**: relocated from `/opt` to `/usr/lib` so it is part of the
  image rather than of the machine's first install.
- **Goose**: its RPM installs under `/usr/lib` and carries the `goose`
  CLI, which `/usr/bin/goose` links to, so the CLI and the app are always
  the same version.

**CodexBar** shows the agents' usage limits and spend in the tray, or with
`codexbar usage` in a terminal. It starts at login (see its Settings); GNOME
needs a tray extension for the icon.

The apps live in the read-only `/usr`, so nothing in them can update itself
in place: they are updated with the image, like everything else.

## Docker

Two daemons, with separate images and containers:

- **Rootful**: the system `docker.service`, for members of the `docker`
  group. It is the CLI's `default` context and has the NVIDIA runtime
  (`--gpus all`).
- **Rootless**: a daemon per user, without root privileges. Set it up once
  (add `--force` if you are in the `docker` group):

  ```sh
  dockerd-rootless-setuptool.sh install
  ```

  This starts it as a systemd user service and switches the CLI to its
  `rootless` context. Switch back with `docker context use default`. To
  keep it running after logout, run `sudo loginctl enable-linger "$USER"`.

## Install

The ISO is a network installer preset to pull the matching image from Docker
Hub, so the install needs a network connection; disk, user and locale are
chosen in the installer as usual, with plain xfs partitions as the default.

Or switch an existing bootc system:

```sh
sudo bootc switch docker.io/ericcurtin044/agenticlinux:kde
```

The ISOs are named for the variant (`agenticlinux-kde-x86_64.iso`), and the
default desktops' are Fedora 45. The Fedora 44 ones are
`agenticlinux-fedora44-kde-x86_64.iso` and so on.

The root filesystem (which holds `/var`, `/home` and `/root`) defaults to xfs
for both `bootc install` and the ISO.

`/tmp` is not a tmpfs: it is `/var/tmp` mounted over it, so one directory on that
filesystem, not limited by RAM. A build that leaves gigabytes there (a cargo
target directory, a Go build cache) cannot fill memory and break everything
else that writes to `/tmp`. Like a tmpfs it is emptied on shutdown and reboot
(`agenticlinux-clean-var-tmp.service`), but not after a crash or power loss, and
systemd-tmpfiles removes files older than 10 days while it runs. `/var/tmp` is
the same directory: keep nothing there that must survive a reboot.

The images are not signed: pulling one, from the ISO or `bootc switch`, relies
on Docker Hub over HTTPS.

## Updates

The whole OS is one image, rebuilt every 4 hours and on every push to `main`;
the variant's tag (`kde`) is the newest. `/etc` and `/var` (so your home
directory) carry over between images.

```sh
bootc status                # running, staged and rollback images
sudo bootc upgrade          # fetch the newest image, boot into it next time
sudo bootc upgrade --apply  # the same, and reboot now
sudo bootc rollback         # boot the previous image next time; again to undo
```

`/var` is shared by both images, so a rollback does not undo changes to your
data.

The default tags (`kde`, `gnome`, ...) moved from Fedora 44 to Fedora 45, so a
machine that followed one is taken to Fedora 45 by its next `bootc upgrade`.
To stay on Fedora 44, switch to its `fedora44-` tag first.

A failed update rolls back by itself. The new image gets three boot attempts,
and if it does not come up healthy the machine returns to the previous image and
does not retry the bad one; see [bootguard](bootguard/README.md).

Every build is also tagged `<variant>-<version>`, the name of a
[release](https://github.com/ericcurtin/agenticlinux/releases). The version is
the build's, `<default Fedora release>.<date>.<run>`, for the Fedora 44 variants
too. Switch to one to pin it, and back to the variant's tag to follow the newest:

```sh
sudo bootc switch docker.io/ericcurtin044/agenticlinux:kde-45.YYYYMMDD.N
```

Nothing updates on its own by default. bootc's timer checks an hour after boot
and about every eight hours after that, and reboots as soon as it finds a new
image:

```sh
sudo systemctl enable --now bootc-fetch-apply-updates.timer
```

## 16k kernels

The `16k-` variants are named for the kernel's page size, not the hardware, so other
16 KiB machines can follow. Each is the variant without the
prefix with its kernel swapped for `kernel-16k` and, for Apple Silicon, the
[Asahi project](https://asahilinux.org/fedora/)'s platform packages (firmware,
m1n1 and U-Boot updaters, Mesa, audio). The branding is AgenticLinux's, as for every
variant. aarch64 only.

There is no installer: the Asahi installer sets up m1n1 and U-Boot, so install an
atomic Fedora Asahi Remix first
([guide](https://github.com/fedora-asahi-remix-atomic-desktops/images#how-to-use)),
then switch:

```sh
sudo bootc switch docker.io/ericcurtin044/agenticlinux:16k-kde
```

`/home` and `/var` carry over and the previous image stays as the rollback, so check
`btrfs filesystem usage /sysroot` first: the image adds about 15 GB for KDE Plasma
(14 GB with no desktop), and `compress=zstd:1` halves that. There is no NVIDIA driver,
CUDA or ROCm; the GPU is Apple's. CI builds and smoke-tests these in a container
only, as it has no Apple hardware to boot.

## 64k kernels

The `64k-` variants are named for the kernel's page size too. Each is the variant
without the prefix with its kernel swapped for one with 64 KiB pages, and the NVIDIA
driver built for it. aarch64 only.

Fedora has no 64k kernel (its `kernel.spec` turns the variant off), so CI builds one
from Fedora's kernel source with [kernel64k.sh](kernel64k.sh): Fedora's aarch64
configuration with the page-size options that Fedora's own RT 64k kernel has, and
nothing else changed. CI builds it once per Fedora kernel version, not per variant.
Its modules are signed with a key made for the
build, not Fedora's, so Secure Boot has to be off, as for the NVIDIA module on every
image.

From a running AgenticLinux, or any bootc system, switch and reboot:

```sh
sudo bootc switch docker.io/ericcurtin044/agenticlinux:64k-kde
```

`/home` and `/var` carry over and the previous image stays as the rollback. To build
one yourself, name the kernel stage, which takes hours:

```sh
docker build --target chunked --build-arg VARIANT=64k-kde --build-arg KERNEL=kernel64k \
  --build-arg BASE=quay.io/fedora-ostree-desktops/kinoite:45 -o type=tar,dest=image.tar .
```

CI builds and smoke-tests these in a container only: no hosted runner has the
hardware, or can boot an arm64 VM.

## GPUs

- Vulkan: Mesa drivers and `vulkaninfo`.
- Apple Silicon: Mesa's Asahi drivers (OpenGL, Vulkan) on the `16k-` variants.
- ROCm (x86_64): HIP runtime, OpenCL, rocBLAS, hipBLAS, hipBLASLt, RCCL,
  `rocminfo`, `rocm-smi`. Containers get GPU access with
  `--device /dev/kfd --device /dev/dri`.
- ROCm on CentOS Stream is EPEL's build: HIP, rocBLAS, hipBLAS, hipBLASLt,
  RCCL, `rocminfo`, `rocm-smi`; EPEL has no ROCm OpenCL.
- NVIDIA: the RPM Fusion driver with the kernel module prebuilt for the
  image's kernel, CUDA driver libraries and `nvidia-container-toolkit`
  registered with Docker (`docker run --gpus all ...`). The module is
  unsigned, so disable Secure Boot or enroll your own MOK. nouveau is
  blacklisted via kernel arguments. On CentOS Stream the driver is RPM
  Fusion's EL10 build, the 580 series. On aarch64 the driver is best effort:
  when RPM Fusion's aarch64 build is broken the image is published without
  it (and with nouveau), see [build.sh](build.sh).

## Building

[packages.txt](packages.txt) lists the RPMs, [build.sh](build.sh) does the
rest, and `usr/` is copied over the image. Each variant's base image is at the
top of the [Dockerfile](Dockerfile); `VARIANT` must match its distribution and, for Fedora, its release. The
published image is the `chunked` target, an OCI layout that Docker only loads
with the containerd image store. Enable it in `/etc/docker/daemon.json`:

```json
{"features": {"containerd-snapshotter": true}}
```

Then:

```sh
docker build --target chunked \
  --build-arg BASE=quay.io/fedora-ostree-desktops/kinoite:45 --build-arg VARIANT=fedora45-kde \
  -o type=tar,dest=image.tar .
docker load -i image.tar   # loads it as agenticlinux:fedora45-kde
```

The smoke test runs in a container of the image; it pulls a small local model
and runs each agent on it, so it takes a while:

```sh
docker build -f test/Dockerfile --build-arg IMAGE=agenticlinux:kde -t agenticlinux:smoke .
docker run --rm agenticlinux:smoke smoke-vm
```

CI also boots each x86_64 image in `qemu` with [test/smoke.sh](test/smoke.sh),
which covers what needs a real boot: Docker (rootful and rootless) and podman.
[build.yml](.github/workflows/build.yml) publishes only if every variant passes
on both architectures. A fork needs the `DOCKER_HUB_USER` variable, the
`DOCKER_HUB_PAT` secret, and an `assets` release with the logo files, which
`build.sh` downloads from `REPO_URL`.
