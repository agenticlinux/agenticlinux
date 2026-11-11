#!/bin/bash
# Runs inside the image build; see Dockerfile. VARIANT and REPO_URL come from
# the build arguments.
set -euxo pipefail

case "$(uname -m)" in
  x86_64)  ARCH=amd64 NODE_ARCH=x64 ;;
  aarch64) ARCH=arm64 NODE_ARCH=arm64 ;;
esac

# The base image sets the distribution, the variant the desktop; the workflow
# has the same table. os-release is read in a subshell: it sets VARIANT too.
read -r DISTRO RELEASE PLATFORM < <(. /usr/lib/os-release; echo "$ID $VERSION_ID ${PLATFORM_ID:-}")
#
# A Fedora variant is named for its release too (fedora45-kde): the name has to
# match the base image's. The plain name (kde) takes whatever release the base
# is, for local builds.
#
# 16k-fedora45-kde (or 16k-kde) is the same variant for a kernel with 16 KiB
# pages, Apple Silicon so far; 64k-fedora45-kde for 64 KiB pages (DGX Spark and
# other Arm servers), with the kernel-64k RPMs kernel64k.sh built in /run/kernel.
case "$VARIANT" in
  16k-*) KPAGE=16k; spec=${VARIANT#16k-} ;;
  64k-*) KPAGE=64k; spec=${VARIANT#64k-} ;;
  *)     KPAGE="";  spec=$VARIANT ;;
esac
case "$spec" in
  fedora[0-9]*-*) want_release=${spec#fedora}; want_release=${want_release%%-*}; desktop=${spec#*-} ;;
  *)              want_release="";                                                desktop=$spec ;;
esac
case "$desktop" in
  kde|centos-kde)     DESKTOP="KDE Plasma" ;;
  gnome|centos-gnome) DESKTOP=GNOME ;;
  sway)               DESKTOP=Sway ;;
  cosmic)             DESKTOP=COSMIC ;;
  xfce)               DESKTOP=Xfce ;;
  budgie)             DESKTOP=Budgie ;;
  base|centos-base)   DESKTOP="no desktop" ;;
  *) echo "unknown VARIANT '$VARIANT'" >&2; exit 1 ;;
esac
case "$desktop" in centos-*) want=centos ;; *) want=fedora ;; esac
[ -z "$KPAGE" ] || [ "$want" = fedora ] || { echo "VARIANT '$VARIANT': $KPAGE variants are Fedora only" >&2; exit 1; }
[ -z "$KPAGE" ] || [ "$(uname -m)" = aarch64 ] || { echo "VARIANT '$VARIANT': $KPAGE variants are aarch64 only" >&2; exit 1; }
[ "$DISTRO" = "$want" ] || { echo "VARIANT '$VARIANT' needs a $want base image, not $DISTRO" >&2; exit 1; }
[ -z "$want_release" ] || [ "$RELEASE" = "$want_release" ] ||
  { echo "VARIANT '$VARIANT' needs a Fedora $want_release base image, not $RELEASE" >&2; exit 1; }

# /root is a dangling symlink to /var/roothome during the build
export HOME=/tmp

# Run a command up to 12 times, 20 s apart
retry() {
  local i
  for i in $(seq 12); do
    "$@" && return
    echo "${*:1:2} failed ($i/12)" >&2
    [ "$i" -lt 12 ] && sleep 20
  done
  return 1
}

# Patient retries: GitHub Releases has had multi-minute outages mid-build
curl() { command curl -fsSL --retry 12 --retry-delay 20 --retry-all-errors "$@"; }
# And dnf the same. Its own retries are immediate and per mirror, so a stall
# on a single-host repository (nvidia.github.io fed one package at under 1000
# bytes/s for 30 s, four times in a row) fails the transaction. Nothing is
# installed until every package has downloaded, so re-running is safe.
#
# RPM Fusion's vlc-plugins-freeworld and libheif-freeworld are never installed.
# Each is built against one release of the package it extends the day that comes
# out, and EPEL's follows days to weeks later. vlc-plugins-freeworld then
# requires a vlc-libs nothing provides (CentOS's multimedia group names it, so
# kde-desktop failed however often it was retried), and libheif-freeworld 1.23.6
# a libheif that EPEL has at 1.23.7 (kf6-kimageformats: every centos-kde build).
# They also supplement those packages, so once EPEL catches up any transaction
# would pull them in: they are excluded from all of them, and the image is the
# same whichever repository is ahead.
#
# A failed attempt also drops the cached repository metadata. dnf keeps what it
# downloaded for the rest of the build, so a retry plans the same transaction
# again, and when the metadata is stale that fails the same way every time: one
# build's was from before Fedora replaced fzf 0.74.4 with 0.74.5, every mirror
# answered 404 for 0.74.4, and all 12 attempts asked for it again while the
# other builds, minutes apart, found 0.74.5. The output goes to stderr: callers
# capture stdout.
dnf_try() {
  command dnf --exclude=vlc-plugins-freeworld --exclude=libheif-freeworld "$@" && return
  command dnf clean metadata >&2 || true
  return 1
}
dnf() { retry dnf_try "$@"; }

# A repository's version tags (v1.2.3, no prereleases), newest first, from its
# releases URL. Not from releases.atom: that feed answered 502/504 for minutes
# and failed six builds, where git ls-remote has not failed. A tag precedes its
# files, so callers check those. Use as var=$(retry release_tags URL): in a for
# list a failed $(...) is ignored, and the build died on "unbound variable".
release_tags() {
  local tags
  tags=$(git ls-remote --tags --refs --sort=-v:refname "${1%/releases}.git" |
    sed -n 's|.*refs/tags/\(v[0-9.]*\)$|\1|p') && [ -n "$tags" ] && echo "$tags"
}

# For a variant that brings its own kernel. protect_running_kernel: the build
# host may be running the base's.
remove_stock_kernel() {
  # shellcheck disable=SC2046
  dnf -y --setopt=protect_running_kernel=false remove $(rpm -qa 'kernel' 'kernel-core' 'kernel-modules*')
}
# KVER, from the one kernel installed. The modules directory ends in +16k or
# +64k, which is what dracut takes.
installed_kernel() {
  local kernels=(/usr/lib/modules/*/)
  [ "${#kernels[@]}" = 1 ] || { echo "expected one kernel, found: ${kernels[*]}" >&2; exit 1; }
  KVER=$(basename "${kernels[0]}")
  kv="" kr=""
}

if [ "$KPAGE" = 16k ]; then
  # Fedora's kernel is replaced by kernel-16k, with the Asahi project's
  # platform packages (firmware, m1n1 and U-Boot updaters, Mesa, audio), as in
  # its own images
  curl -o /etc/yum.repos.d/asahi-bootstrap.repo \
    "https://copr.fedorainfracloud.org/coprs/g/asahi/fedora-remix-branding/repo/fedora-${RELEASE}/group_asahi-fedora-remix-branding-fedora-${RELEASE}.repo"
  dnf -y install asahi-repos
  rm /etc/yum.repos.d/asahi-bootstrap.repo # asahi-repos has the same repository
  # Its Mesa and U-Boot rank above Fedora's newer ones, but dnf ignores that for
  # an installed package, hence the pins below
  sed -i 's/^priority=.*/priority=5/' /etc/yum.repos.d/group_asahi-mesa.repo /etc/yum.repos.d/group_asahi-u-boot.repo
  remove_stock_kernel
  platform="asahi-platform-metapackage asahi-platform-metapackage-core asahi-platform-metapackage-mesa asahi-platform-metapackage-audio"
  [ "$desktop" != kde ] || platform="$platform asahi-platform-metapackage-plasma"
  # shellcheck disable=SC2086
  dnf -y install $platform alsa-ucm-asahi fedora-asahi-remix-scripts tiny-dfr grub2-efi-aa64-modules \
    uboot-images-armv8 asahi-fwupdate dracut-asahi update-m1n1 aajohan-comfortaa-fonts
  # Pin what is installed to each Asahi repository's newest build (Mesa, U-Boot, kernel tools)
  rpm -qa --qf '%{NAME}\n' | sort -u > /tmp/installed.names
  for repo in kernel mesa u-boot; do
    pins=$(dnf -q repoquery --repo="copr:copr.fedorainfracloud.org:group_asahi:$repo" --latest-limit=1 \
        --qf '%{name} %{epoch}:%{version}-%{release}.%{arch}\n' |
      awk 'NR==FNR{have[$1]=1;next} ($1 in have) && $2 !~ /\.src$/ {print $1"-"$2}' /tmp/installed.names -)
    # shellcheck disable=SC2086
    [ -z "$pins" ] || dnf -y install --allowerasing $pins
  done
  rm /tmp/installed.names
  # U-Boot loads EFI/BOOT/BOOTAA64.EFI, which wants grubaa64.efi beside it, as
  # the Asahi installer lays it out; Fedora's is only under EFI/fedora
  for efidir in /usr/lib/efi/grub2/*/EFI; do
    install -Dm644 "$efidir/fedora/grubaa64.efi" "$efidir/BOOT/grubaa64.efi"
  done
  installed_kernel
elif [ "$KPAGE" = 64k ]; then
  # Fedora's kernel is replaced by the kernel-64k kernel64k.sh built (its devel
  # packages are installed with the NVIDIA module's build, below)
  remove_stock_kernel
  dnf -y install /run/kernel/kernel-64k-{,core-,modules-,modules-core-,modules-extra-}[0-9]*.rpm
  installed_kernel
else
  KVER=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
  read -r kv kr < <(rpm -q kernel --qf '%{VERSION} %{RELEASE}\n')
fi
# What differs by distribution: RPM Fusion's branch, the NVIDIA driver (the
# EL branch has it as a versioned stream), ID_LIKE, and where the kernel-devel
# matching the kernel comes from. akmods requires it, and left to dnf the
# repositories' newest comes with its kernel as a second one. Both images can
# be built ahead of the mirrors: CentOS Stream's always is, and Fedora's picks
# up a kernel the day it goes stable, while some mirrors still serve the
# metadata from before (kernel-devel-7.2.6-200.fc44 was "No match" on one x86_64
# build and found on the rest). The build systems keep every build, so the
# packages come from there when the mirrors don't have them. That is
# kernel-devel-matched as well as kernel-devel: akmods requires the matched
# one for the installed kernel, and a mirror can lack it too, including one
# already past the kernel (7.2.7 in updates, 7.2.6 not yet in updates-archive).
case "$DISTRO" in
  fedora)
    RPMFUSION=fedora NVIDIA=akmod-nvidia CUDA=xorg-x11-drv-nvidia-cuda ID_LIKE=fedora
    # Fedora 45 on aarch64 (DGX Spark and other GB10 machines, whose NVIDIA
    # driver is the 580 branch) takes RPM Fusion's 580xx stream: the current
    # 615 one needs a Tegra library nothing provides, see nvidia_install
    if [ "$(uname -m)" = aarch64 ] && [ "$RELEASE" -ge 45 ]; then
      NVIDIA=akmod-nvidia-580xx CUDA=xorg-x11-drv-nvidia-580xx-cuda
    fi
    koji="https://kojipkgs.fedoraproject.org/packages/kernel/${kv}/${kr}/$(uname -m)"
    KDEVEL=""
    # 16k hardware so far (Apple Silicon) has no NVIDIA GPU: no module to build
    kdevel="kernel-devel kernel-devel-matched"
    [ -z "$KPAGE" ] || kdevel=""
    for p in $kdevel; do
      if [ -n "$(dnf -q repoquery --available "${p}-${KVER}")" ]; then
        KDEVEL="$KDEVEL ${p}-${KVER}"
      else
        KDEVEL="$KDEVEL $koji/${p}-${KVER}.rpm"
      fi
    done
    [ "$KPAGE" != 64k ] || KDEVEL=$(echo /run/kernel/kernel-64k-devel-{,matched-}[0-9]*.rpm)
    ;;
  centos)
    RPMFUSION=el NVIDIA=akmod-nvidia-580xx CUDA=xorg-x11-drv-nvidia-580xx-cuda ID_LIKE="rhel centos fedora"
    koji="https://kojihub.stream.centos.org/kojifiles/packages/kernel/${kv}/${kr}/$(uname -m)"
    KDEVEL="$koji/kernel-devel-${KVER}.rpm $koji/kernel-devel-matched-${KVER}.rpm"
    ;;
esac

# --- Repositories -----------------------------------------------------------
# CentOS: EPEL for the desktops beyond GNOME and most of the tools, CRB for
# what EPEL builds against
if [ "$DISTRO" = centos ]; then
  # The image's nftables (1.1.7-1) is in no repository yet. The kde-desktop
  # group's python3-nftables needs the repositories' own, and the group install
  # failed on "cannot install both nftables" in all 12 tries. Take the
  # repositories' version first; a no-op once they have the image's.
  dnf -y distro-sync nftables
  dnf -y install epel-release
  crb enable
  # Cisco's openh264 build, as fedora-cisco-openh264 on Fedora; EPEL 10's
  # epel-release no longer ships the repo file EPEL 9's had
  cat > /etc/yum.repos.d/epel-cisco-openh264.repo <<EOF
[epel-cisco-openh264]
name=Extra Packages for Enterprise Linux ${RELEASE} openh264 (From Cisco) - \$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-cisco-openh264-${RELEASE}&arch=\$basearch
enabled=1
metadata_expire=14d
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-${RELEASE}
EOF
fi
# dnf has no mirror list to fail over in for these two bare URLs.
# mirrors.rpmfusion.org redirects to one mirror, and when that stalls
# (mirror.fcix.net did) so does every retry. download1 is the origin: try it
# first.
rpmfusion_release() {
  local host t urls
  for host in download1 mirrors; do
    urls=()
    for t in free nonfree; do
      urls+=("https://${host}.rpmfusion.org/${t}/${RPMFUSION}/rpmfusion-${t}-release-${RELEASE}.noarch.rpm")
    done
    command dnf -y install "${urls[@]}" && return
  done
  return 1
}
retry rpmfusion_release
for r in "https://download.docker.com/linux/${DISTRO}/docker-ce.repo" \
         https://mise.jdx.dev/rpm/mise.repo \
         https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo; do
  curl -o "/etc/yum.repos.d/${r##*/}" "$r"
done

# --- Desktop (CentOS) -------------------------------------------------------
# CentOS's bootc image has no desktop, so it is a group install: GNOME from
# CentOS, KDE Plasma from EPEL, plus the groups their installer environments
# add. Not Core and Standard: the image is complete already, and they pin
# tools to package versions the image is ahead of, failing the transaction.
if [ "$DISTRO" = centos ]; then
  case "$VARIANT" in
    centos-gnome) groups="gnome-desktop workstation-product" ;;
    centos-kde)   groups="kde-desktop" ;;
    *)            groups="" ;;
  esac
  if [ -n "$groups" ]; then
    # shellcheck disable=SC2086
    dnf -y group install base-graphical fonts input-methods multimedia hardware-support \
      guest-desktop-agents networkmanager-submodules desktop-accessibility $groups
  fi
fi

# --- Packages ---------------------------------------------------------------
# Docker Sandboxes from its nightly build of main (a rolling release tag, the
# same asset names as the tagged releases)
curl -o /tmp/docker-sbx.rpm \
  "https://github.com/docker/sbx-releases/releases/download/nightly/DockerSandboxes-linux-${ARCH}-rockylinux8.rpm"
# shellcheck disable=SC2046,SC2086
PACKAGES=$(sed 's/#.*//' /tmp/packages.txt)
# no NVIDIA GPU on 16k hardware, so no driver build or container toolkit
[ "$KPAGE" != 16k ] || PACKAGES=$(grep -v -x -E 'akmods|nvidia-container-toolkit' <<<"$PACKAGES")
dnf -y install $PACKAGES $KDEVEL /tmp/docker-sbx.rpm

# vim is the editor; the base images also have nano. Fedora's makes it EDITOR
# with nano-default-editor, which vim-default-editor replaces. CentOS has
# neither, so EDITOR stays unset there and tools fall back to vi.
if rpm -q nano-default-editor >/dev/null; then
  dnf -y swap nano-default-editor vim-default-editor
fi
if rpm -q nano >/dev/null; then dnf -y remove nano; fi

# ROCm is x86_64 only, in Fedora and in EPEL (which has no OpenCL packages)
if [ "$(uname -m)" = x86_64 ]; then
  rocm="rocm-hip rocm-runtime rocm-smi rocminfo rocblas hipblas hipblaslt rccl"
  [ "$DISTRO" = centos ] || rocm="$rocm rocm-opencl rocm-clinfo"
  # shellcheck disable=SC2086
  dnf -y install $rocm
fi

# Kata Containers (Fedora only; EPEL has none). Its %post builds the guest
# initrd for the running kernel, which a build has not got, so it goes in
# without scriptlets (like akmod-nvidia, below) after the dependencies that
# need theirs, and kata-osbuilder-generate.service builds the initrd at boot.
# The packaged configuration names a vmlinux.container that osbuilder never
# creates (it links vmlinuz.container) and, on aarch64, firmware in aavmf/
# where edk2-aarch64 has AAVMF/: /etc gets a corrected copy.
if [ "$DISTRO" = fedora ]; then
  dnf -y install binutils dbus-daemon
  dnf -y install --setopt=tsflags=noscripts kata-containers
  ln -sf ../kata-osbuilder-generate.service /usr/lib/systemd/system/multi-user.target.wants/
  install -d /etc/kata-containers
  sed -e 's|/vmlinux\.container|/vmlinuz.container|' -e 's|/usr/share/aavmf/|/usr/share/AAVMF/|' \
    /usr/share/kata-containers/defaults/configuration.toml > /etc/kata-containers/configuration.toml
fi

# /usr is read-only on a bootc host, so build the NVIDIA kernel module now.
# akmod-nvidia's %post only works in rpm-ostree's sandbox; skip it and run
# akmods ourselves, then drop the build-time packages. akmods exits 0 on a
# failed build, hence the modinfo check.
#
# On x86_64 the driver is required: one that stops building fails the build
# rather than quietly shipping nouveau. On aarch64 it is best effort: RPM
# Fusion's aarch64 driver breaks in ways x86_64's does not (615.71.09-3 needs
# a Tegra library nothing provides, and the 595 dnf falls back to no longer
# builds) and an NVIDIA GPU in an aarch64 desktop is rare. The image then
# keeps nouveau, which the kernel arguments would otherwise blacklist.
nvidia_install() {
  dnf -y install --setopt=tsflags=noscripts "$NVIDIA" &&
    akmods --force --kernels "${KVER}" &&
    modinfo -k "${KVER}" nvidia >/dev/null &&
    dnf -y install "$CUDA"
}
if [ "$KPAGE" = 16k ]; then
  rm -f /usr/lib/bootc/kargs.d/10-nvidia.toml
elif nvidia_install; then
  :
elif [ "$(uname -m)" = aarch64 ]; then
  tail -n 30 /var/cache/akmods/*/*.failed.log || true
  echo "WARNING: the NVIDIA driver could not be installed, building without it" >&2
  rm /usr/lib/bootc/kargs.d/10-nvidia.toml
else
  exit 1
fi
# the -64k kernel's devel package is named for its version without the +64k
kdevel_pkg=kernel-devel-${KVER}
[ "$KPAGE" != 64k ] || kdevel_pkg=kernel-64k-devel-${KVER%+64k}
for p in "$NVIDIA" "$kdevel_pkg"; do
  if rpm -q "$p" >/dev/null; then dnf -y remove "$p"; fi
done
[ "$KPAGE" = 16k ] || nvidia-ctk runtime configure --runtime=docker

# --- Agents -----------------------------------------------------------------
# Upstream Node bundles its own SQLite; OpenClaw refuses the system SQLite the
# distribution's Node links against (WAL corruption bug in 3.51.2).
NODE=$(curl https://nodejs.org/dist/index.json |
  python3 -c 'import sys,json; print(next(v["version"] for v in json.load(sys.stdin) if v["version"].startswith("v24") and v["lts"]))')
curl "https://nodejs.org/dist/${NODE}/node-${NODE}-linux-${NODE_ARCH}.tar.xz" |
  tar xJ -C /usr --strip-components=1 --no-same-owner \
    --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
npm install -g --prefix /usr @anthropic-ai/claude-code @openai/codex openclaw

# OpenCode 2 is on neither npm (opencode-ai is 1.x) nor GitHub's "latest": take
# the newest stable tag with the CLI and desktop RPM uploaded. The x64
# baseline CLI runs without AVX2.
oc_url=https://github.com/anomalyco/opencode/releases
oc_cli=opencode-linux-${NODE_ARCH/x64/x64-baseline}.tar.gz
oc_rpm=opencode-desktop-linux-$(uname -m).rpm
oc_tags=$(retry release_tags "$oc_url")
for oc in $oc_tags; do
  for f in $oc_cli $oc_rpm; do
    command curl -fsIL --retry 5 -o /dev/null "$oc_url/download/$oc/$f" || continue 2
  done
  break
done
curl "$oc_url/download/$oc/$oc_cli" | tar xz -C /usr/bin --no-same-owner opencode
/usr/bin/opencode --version

curl -o /usr/bin/llmman \
  "https://github.com/llmmanorg/llmman/releases/latest/download/llmman-$(uname -m)-unknown-linux-gnu"
chmod 755 /usr/bin/llmman
/usr/bin/llmman --version

# herdr, the terminal workspace the agents run in: a static binary per
# architecture, released the way llmman is
curl -o /usr/bin/herdr \
  "https://github.com/herdrdev/herdr/releases/latest/download/herdr-linux-$(uname -m)"
chmod 755 /usr/bin/herdr
/usr/bin/herdr --version

# OpenShell: the CLI, gateway (a user unit, left disabled) and policy prover,
# from the newest release with all three RPMs for this architecture, checked
# against its checksum file. Built on Fedora, but CentOS takes them too.
os_url=https://github.com/NVIDIA/OpenShell/releases
os_tags=$(retry release_tags "$os_url")
mkdir /tmp/openshell
(
  cd /tmp/openshell
  for os in $os_tags; do
    command curl -fsL --retry 5 -o sums "$os_url/download/$os/openshell-checksums-sha256.txt" || continue
    grep -E " openshell(-gateway|-prover)?-[0-9][^ ]*\.$(uname -m)\.rpm$" sums > rpms.sums || true
    [ "$(wc -l < rpms.sums)" = 3 ] && break
  done
  [ "$(wc -l < rpms.sums)" = 3 ]
  for f in $(awk '{print $2}' rpms.sums); do curl -O "$os_url/download/$os/$f"; done
  sha256sum -c rpms.sums
  dnf -y install /tmp/openshell/*.rpm
)
/usr/bin/openshell --version

# --- Desktop apps -----------------------------------------------------------
# The agents' desktop apps that come as RPMs: ChatGPT (Codex is part of it)
# and OpenCode. Claude's is a .deb only.
curl -o /tmp/chatgpt.rpm \
  "https://persistent.oaistatic.com/codex-app-prod/linux/rpm/latest/chatgpt.$(uname -m).rpm"
curl -o /tmp/opencode-desktop.rpm "$oc_url/download/$oc/$oc_rpm"
# OpenCode's RPM installs into /opt, which bootc keeps in the mutable /var
# (there after the first install, never updated), so it moves under /usr.
# Fedora's /opt is a dangling link; rpm needs its target to exist.
install -d "$(readlink -f /opt)"
dnf -y install /tmp/chatgpt.rpm /tmp/opencode-desktop.rpm
# Updates come with the image; ChatGPT's repository would be one more host
# for every dnf call to reach
sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/chatgpt.repo
mv /opt/OpenCode /usr/lib/opencode-desktop
sed -i 's|/opt/OpenCode/|/usr/lib/opencode-desktop/|' \
  /usr/share/applications/opencode-desktop.desktop /usr/share/applications/ai.opencode.desktop.desktop
# The %post's alternatives entry points into /opt too
update-alternatives --remove ai.opencode /opt/OpenCode/ai.opencode || true
ln -sfn ../lib/opencode-desktop/ai.opencode /usr/bin/ai.opencode
ln -sfn ../lib/opencode-desktop/ai.opencode /usr/bin/opencode-desktop

# Goose: the desktop app's RPM, from the newest release that has this
# architecture's uploaded. Releases are published before their assets are (the
# last of 1.51.0's came 18 hours later) and 1.47.0 has no arm64 RPM at all.
# The file names say arm64 and x86_64, where uname says aarch64. The RPM
# installs into /usr/lib already, and carries the goose CLI at
# resources/bin/goose: the same binary, at the same version, as the release's
# standalone archive, so /usr/bin/goose links to it instead of a second 285 MB
# copy. goose-desktop is the name llmman looks for.
goose_url=https://github.com/aaif-goose/goose/releases
goose_tags=$(retry release_tags "$goose_url")
for goose in $goose_tags; do
  goose_rpm=Goose-${goose#v}-1.${ARCH/amd64/x86_64}.rpm
  command curl -fsIL --retry 5 -o /dev/null "$goose_url/download/$goose/$goose_rpm" && break
done
curl -o /tmp/goose.rpm "$goose_url/download/$goose/$goose_rpm"
dnf -y install /tmp/goose.rpm
ln -sfn ../lib/Goose/resources/bin/goose /usr/bin/goose
ln -sfn ../lib/Goose/Goose /usr/bin/goose-desktop
/usr/bin/goose --version

# CodexBar: a Swift CLI and a Qt tray app over it, from the newest stable
# release whose Linux archives are all uploaded (that takes minutes after
# publishing). The CLI finds its resource bundle beside its resolved path,
# so its archive stays whole.
cb_url=https://github.com/steipete/CodexBar/releases
cb_tags=$(retry release_tags "$cb_url")
for cb in $cb_tags; do
  files=$(echo CodexBar{CLI,Desktop}-"$cb-linux-$(uname -m)".tar.gz{,.sha256})
  for f in $files; do
    command curl -fsIL --retry 5 -o /dev/null "$cb_url/download/$cb/$f" || continue 2
  done
  break
done
mkdir -p /tmp/codexbar /usr/lib/codexbar
(
  cd /tmp/codexbar
  for f in $files; do curl -O "$cb_url/download/$cb/$f"; done
  sha256sum -c ./*.sha256
  tar xzf CodexBarCLI-*.tar.gz -C /usr/lib/codexbar --no-same-owner
  tar xzf CodexBarDesktop-*.tar.gz --strip-components=1 --no-same-owner
)
ln -sfn ../lib/codexbar/CodexBarCLI /usr/bin/codexbar
install -m755 /tmp/codexbar/bin/codexbar-linux /usr/bin/codexbar-linux
install -Dm644 /tmp/codexbar/Integrations/Linux/icon.svg /usr/share/icons/hicolor/scalable/apps/codexbar.svg
install -Dm644 /tmp/codexbar/LICENSE /usr/share/licenses/codexbar/LICENSE
install -d /etc/xdg/autostart
cat > /etc/xdg/autostart/com.steipete.CodexBar.desktop <<EOF
[Desktop Entry]
Type=Application
Name=CodexBar
Exec=/usr/libexec/codexbar-autostart
Icon=codexbar
Terminal=false
Hidden=false
EOF
/usr/bin/codexbar --version

# --- Browser ----------------------------------------------------------------
# Google Chrome from Google's repository (signed, one per architecture; the
# RPM's %post would write the same file). Chrome installs into /opt like
# OpenCode and moves under /usr the same way: its launcher finds its files
# through readlink -f, the menu entries go through
# /usr/bin/google-chrome-stable, and only GNOME's default-apps entry names the
# directory. The repository and the daily cron job that re-adds it are how
# Google updates a mutable system; here updates come with the image.
cat > /etc/yum.repos.d/google-chrome.repo <<EOF
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$(uname -m)
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
dnf -y install google-chrome-stable
sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/google-chrome.repo
rm /etc/cron.daily/google-chrome
mv /opt/google/chrome /usr/lib/google-chrome
rmdir /opt/google
ln -sfn ../lib/google-chrome/google-chrome /usr/bin/google-chrome-stable
sed -i 's|/opt/google/chrome/|/usr/lib/google-chrome/|' \
  /usr/share/gnome-control-center/default-apps/google-chrome.xml

# --- Identity ---------------------------------------------------------------
# A remix of Fedora's or CentOS's packages, not Fedora or CentOS: their
# trademark guidelines allow that, not a modified distribution under their
# name and logo. Fedora's generic-logos is an unbranded drop-in for its
# artwork package (same file names and provides); CentOS has none, so
# centos-logos stays and its artwork is overwritten below. The release files
# are plain text and overwritten too; the release packages stay, many
# packages require them. Done after every dnf transaction so no update can
# put the originals back.
if rpm -q fedora-logos >/dev/null; then
  dnf -y swap fedora-logos generic-logos
fi
# Fedora's first-run app and its Fedora-logo icon theme override, where present
for p in plasma-welcome-fedora breeze-icon-theme-fedora; do
  if rpm -q "$p" >/dev/null; then dnf -y remove "$p"; fi
done

# The logo is not in git; it is a release asset of the repository
mkdir -p /tmp/logo
sizes="16 22 24 32 48 64 128 256 512"
files=agenticlinux-logo.svg
for s in $sizes; do files="$files agenticlinux-logo-$s.png"; done
for f in $files; do
  curl -o "/tmp/logo/$f" "${REPO_URL}/releases/download/assets/$f"
done
install -Dm644 /tmp/logo/agenticlinux-logo.svg /usr/share/icons/hicolor/scalable/apps/agenticlinux.svg
for s in $sizes; do
  install -Dm644 "/tmp/logo/agenticlinux-logo-$s.png" "/usr/share/icons/hicolor/${s}x${s}/apps/agenticlinux.png"
done
install -Dm644 /tmp/logo/agenticlinux-logo.svg /usr/share/pixmaps/agenticlinux-logo.svg
install -Dm644 /tmp/logo/agenticlinux-logo-256.png /usr/share/pixmaps/agenticlinux-logo.png

# generic-logos keeps fedora-logos' file names with placeholder art (a
# dancing hot dog), centos-logos has CentOS's under mostly the same names,
# and those names are what the desktops ask for: Plasma's launcher icon is
# "start-here", the system logo icon "fedora-logo-icon", anaconda, GDM and
# the greeters read the pixmaps. Put the AgenticLinux logo behind every one,
# at the size the icon directory names.
for p in generic-logos centos-logos; do
  rpm -q "$p" >/dev/null || continue
  for f in $(rpm -ql "$p" | grep -E '/(fedora[-_]logo|fedora-gdm-logo|centos[-_]logo|start-here|system-logo|bootlogo)[^/]*\.(png|svg)$'); do
    [ -L "$f" ] && continue
    case "$f" in
      *.svg) install -m644 /tmp/logo/agenticlinux-logo.svg "$f" ;;
      *.png)
        s=256
        [[ $f =~ /([0-9]+)x[0-9]+/ ]] && s=${BASH_REMATCH[1]}
        [[ $f =~ _([0-9]+)\.png$ ]] && s=${BASH_REMATCH[1]}
        [[ $f == *-small.png ]] && s=128
        case " $sizes " in *" $s "*) ;; *) s=256 ;; esac
        install -m644 "/tmp/logo/agenticlinux-logo-$s.png" "$f"
        ;;
    esac
  done
done
# GTK trusts an icon cache that is newer than its directory, so refresh it
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -f -t -q /usr/share/icons/hicolor
else
  touch /usr/share/icons/hicolor
fi

# GNOME's background-logo extension is preset to the distribution's logo
schemas=/usr/share/glib-2.0/schemas
if [ -e "$schemas/org.fedorahosted.background-logo-extension.gschema.xml" ]; then
  cat > "$schemas/zz-agenticlinux-background-logo.gschema.override" <<EOF
[org.fedorahosted.background-logo-extension]
logo-file='/usr/share/pixmaps/agenticlinux-logo.svg'
logo-file-dark='/usr/share/pixmaps/agenticlinux-logo.svg'
EOF
  glib-compile-schemas "$schemas"
fi

# --- Wallpaper --------------------------------------------------------------
# The default wallpaper is the distribution's release artwork, wired up by
# its backgrounds packages: gsettings overrides for GNOME and Budgie,
# /usr/share/wallpapers/Default for Plasma (its look-and-feel and lock screen
# are preset to it), and /usr/share/backgrounds/default*.jxl for Sway, Xfce,
# COSMIC and the greeters. Render the AgenticLinux wallpaper and point each
# of those at it. The renderers are build-time only. The compat links keep
# their names (Fedora's are JPEG XL), so the image is encoded as both.
bg=/usr/share/backgrounds/agenticlinux
compat=$(ls /usr/share/backgrounds/default.* /usr/share/backgrounds/default-dark.* \
            /usr/share/backgrounds/images/default*.* 2>/dev/null || true)
if [ -n "$compat" ] || [ -d /usr/share/wallpapers ] ||
   [ -e "$schemas/org.gnome.desktop.background.gschema.xml" ]; then
  tools=""
  for p in librsvg2-tools libjxl-utils; do rpm -q "$p" >/dev/null || tools="$tools $p"; done
  # shellcheck disable=SC2086
  [ -z "$tools" ] || dnf -y install $tools
  install -m644 /tmp/logo/agenticlinux-logo.svg "$bg/agenticlinux-logo.svg"
  rsvg-convert -w 3840 -h 2160 -o "$bg/agenticlinux.png" "$bg/agenticlinux.svg"
  cjxl -d 0 --quiet "$bg/agenticlinux.png" "$bg/agenticlinux.jxl"
  # shellcheck disable=SC2086
  [ -z "$tools" ] || dnf -y remove $tools

  for f in $compat; do
    case "$f" in
      *.jxl) ln -sf "$bg/agenticlinux.jxl" "$f" ;;
      *.png) ln -sf "$bg/agenticlinux.png" "$f" ;;
    esac
  done
  if [ -L /usr/share/backgrounds/default.xml ] || [ -e /usr/share/backgrounds/default.xml ]; then
    cat > "$bg/agenticlinux.xml" <<EOF
<background>
  <static>
    <duration>86400.0</duration>
    <file>$bg/agenticlinux.jxl</file>
  </static>
</background>
EOF
    ln -sf "$bg/agenticlinux.xml" /usr/share/backgrounds/default.xml
  fi

  if [ -e "$schemas/org.gnome.desktop.background.gschema.xml" ]; then
    cat > "$schemas/zz-agenticlinux-background.gschema.override" <<EOF
[org.gnome.desktop.background]
picture-uri='file://$bg/agenticlinux.jxl'
picture-uri-dark='file://$bg/agenticlinux.jxl'

[org.gnome.desktop.screensaver]
picture-uri='file://$bg/agenticlinux.jxl'
EOF
    if [ -e "$schemas/x.dm.slick-greeter.gschema.xml" ]; then
      cat >> "$schemas/zz-agenticlinux-background.gschema.override" <<EOF

[x.dm.slick-greeter]
background='$bg/agenticlinux.jxl'
EOF
    fi
    glib-compile-schemas "$schemas"
  fi

  if [ -d /usr/share/wallpapers ]; then
    install -d /usr/share/wallpapers/AgenticLinux/contents/images
    ln -sf "$bg/agenticlinux.png" /usr/share/wallpapers/AgenticLinux/contents/images/3840x2160.png
    ln -sf "$bg/agenticlinux.png" /usr/share/wallpapers/AgenticLinux/contents/screenshot.png
    cat > /usr/share/wallpapers/AgenticLinux/metadata.json <<EOF
{
  "KPlugin": {
    "Id": "AgenticLinux",
    "Name": "AgenticLinux",
    "License": "Apache-2.0"
  }
}
EOF
    if [ -L /usr/share/wallpapers/Default ]; then
      ln -sfn AgenticLinux /usr/share/wallpapers/Default
    fi
  fi
fi

# Fedora's Plasma look-and-feel stays (kde-settings and the Plasma defaults
# name it); only what it shows changes: its wallpaper above, its name here
for f in /usr/share/plasma/look-and-feel/org.fedoraproject.fedora*.desktop/metadata.json; do
  [ -e "$f" ] || continue
  sed -i -e 's/"Name": "Fedora/"Name": "AgenticLinux/' \
         -e 's/"Description": "[^"]*"/"Description": "AgenticLinux theme"/' "$f"
done

cat > /usr/lib/os-release <<EOF
NAME="AgenticLinux"
VERSION="${RELEASE} (${DESKTOP})"
ID=agenticlinux
ID_LIKE="${ID_LIKE}"
VERSION_ID=${RELEASE}
PRETTY_NAME="AgenticLinux ${RELEASE} (${DESKTOP})"
ANSI_COLOR="0;38;2;124;108;248"
LOGO=agenticlinux
CPE_NAME="cpe:/o:agenticlinux:agenticlinux:${RELEASE}"
DEFAULT_HOSTNAME="agenticlinux"
HOME_URL="${REPO_URL}"
DOCUMENTATION_URL="${REPO_URL}#readme"
SUPPORT_URL="${REPO_URL}/issues"
BUG_REPORT_URL="${REPO_URL}/issues"
VARIANT="${DESKTOP}"
VARIANT_ID=${VARIANT}
EOF
# dnf reads the platform module stream from here
[ -z "$PLATFORM" ] || echo "PLATFORM_ID=\"${PLATFORM}\"" >> /usr/lib/os-release
# The release file /etc/system-release and /etc/redhat-release link to (under
# /usr/lib on Fedora, /etc/centos-release itself on CentOS), and the CPE file
for f in /usr/lib/fedora-release /etc/centos-release; do
  [ -f "$f" ] && [ ! -L "$f" ] && echo "AgenticLinux release ${RELEASE}" > "$f"
done
for f in /usr/lib/system-release-cpe /etc/system-release-cpe; do
  [ -f "$f" ] && [ ! -L "$f" ] && echo "cpe:/o:agenticlinux:agenticlinux:${RELEASE}" > "$f"
done

# The boot splash's watermark was the logo package's too, and it is baked into
# the initramfs, so that is rebuilt the way the bootc images build it (their
# dracut.conf.d already says hostonly=no). It runs after os-release is written:
# dracut copies that into the initramfs, whose hostname default was Fedora's.
# (a 16k or 64k kernel has no initramfs yet, so it is built with or without a
# splash)
if [ -d /usr/share/plymouth/themes/spinner ]; then
  install -m644 /tmp/logo/agenticlinux-logo-64.png /usr/share/plymouth/themes/spinner/watermark.png
fi
if [ -d /usr/share/plymouth/themes/spinner ] || [ -n "$KPAGE" ]; then
  dracut --no-hostonly --kver "$KVER" --reproducible --add ostree --tmpdir /tmp -f /tmp/initramfs.img
  install -m600 /tmp/initramfs.img "/usr/lib/modules/$KVER/initramfs.img"
fi

# CentOS's image had no display manager until the group install. Presets
# enable GDM and SDDM; Plasma's own login manager has none.
#
# The default target is set where Fedora's desktop images set theirs, in
# /usr/lib, not with systemctl set-default: that writes
# /etc/systemd/system/default.target, which outranks the generator directory
# systemd-run-generator redirects default.target from, so the smoke test's
# systemd.run= would be ignored and the guest would boot to the login prompt.
if [ "$DISTRO" = centos ] && [ "$DESKTOP" != "no desktop" ]; then
  ln -sfn graphical.target /usr/lib/systemd/system/default.target
  rm -f /etc/systemd/system/default.target
  if [ ! -e /etc/systemd/system/display-manager.service ]; then
    for dm in gdm plasmalogin sddm; do
      [ -e "/usr/lib/systemd/system/$dm.service" ] || continue
      systemctl enable "$dm.service"
      break
    done
  fi
fi

# The second empties /tmp (it is /var/tmp) on shutdown, as the tmpfs it replaced
systemctl enable docker.service agenticlinux-clean-var-tmp.service

# The base images keep file capabilities (newuidmap's, which rootless podman
# needs) in ostree's own metadata, which BuildKit does not apply, so the
# repacking in rechunk.sh would drop them. Set them again from the rpmdb.
rpm -qa --qf '[%{FILECAPS}\t%{FILENAMES}\n]' | grep -v -e '^(none)' -e $'^\t' |
  while IFS=$'\t' read -r cap f; do
    if [ -e "$f" ]; then setcap "$cap" "$f"; fi
  done
[[ $(getcap /usr/bin/newuidmap) == *cap_setuid* ]]

# /tmp was HOME for the build, so npm's cache and the like are dotfiles there.
# Not /run/*: BuildKit bind-mounts its resolv.conf where the image's
# /etc/resolv.conf points, /run/systemd/resolve/stub-resolv.conf, and rm on
# a mountpoint fails the build. /run is a tmpfs on the host anyway.
dnf clean all
rm -rf /var/cache /var/lib/dnf /var/log/* /run/akmods /run/dnf /tmp/* /tmp/.[!.]*
