# AgenticLinux: a bootc desktop with Docker Engine, Docker Sandboxes, llmman,
# GPU runtimes (Vulkan, ROCm, NVIDIA/CUDA) and a developer toolset preinstalled.
#
# BASE is the upstream bootc image a variant is built from and VARIANT the
# variant's name (the public tag). The pairs, also in the workflow's table:
#   fedora45-X fedora44-X, X one of kde gnome sway cosmic xfce budgie base
#     quay.io/fedora-ostree-desktops/{kinoite,silverblue,sway-atomic,
#     cosmic-atomic,xfce-atomic,budgie-atomic,base-atomic}:<45 or 44>
#     (the plain name, kde, is a tag of fedora45-kde, and builds locally
#     against whatever release BASE is)
#   centos-kde centos-gnome centos-base
#     quay.io/centos-bootc/centos-bootc:stream10 (the desktop is installed
#     by build.sh; CentOS has no desktop images)
#   16k-fedora45-X, X as above (and 16k-X for the plain name)
#     the same images, with a 16 KiB-page kernel swapped in by build.sh
#   64k-fedora45-X, X as above (and 64k-X for the plain name)
#     the same, with a 64 KiB-page kernel built from Fedora's source:
#     KERNEL=kernel64k builds it (hours), KERNEL=<image> takes a built one
# REPO_URL is the project's home: the OS identity files point at it and the
# logo is downloaded from its release assets. VERSION is the version bootc
# status shows.
#
# The default target has over 250 layers, too many for Docker's overlay2
# store. The published one is the chunked target, the same image repacked
# (rechunk.sh) as an OCI layout:
#   docker build --target chunked -o type=tar,dest=image.tar . &&
#     docker load -i image.tar
ARG BASE=quay.io/fedora-ostree-desktops/base-atomic:45
# The 64k variants' kernel RPMs: a stage or image; the other variants have none
ARG KERNEL=nokernel
ARG FEDORA=45
# rpm-ostree for the repacking; CentOS's hangs in a container build
ARG RECHUNKER=quay.io/fedora/fedora-bootc:45

FROM scratch AS nokernel

# Pin the kernel's version with KERNEL_NVR, e.g. 7.2.15-300.fc45
FROM quay.io/fedora/fedora:${FEDORA} AS kernel64k-build
ARG KERNEL_NVR=
RUN --mount=type=bind,source=kernel64k.sh,target=/kernel64k.sh KERNEL_NVR="$KERNEL_NVR" /kernel64k.sh

FROM scratch AS kernel64k
COPY --from=kernel64k-build /out/ /

FROM ${KERNEL} AS kernel

# bootguard (automatic rollback of a failed update) is built on the variant's own
# base, so it links against the distribution it runs on. dnf gets the patience
# build.sh gives it, including fresh metadata for every retry (stale metadata
# fails the same way each time); cargo has its own retries for crates.io. HOME
# is /tmp as in build.sh: /root is a dangling symlink in these images, so cargo
# cannot use it.
FROM ${BASE} AS bootguard
RUN for i in $(seq 12); do dnf install -y cargo && break; \
      [ "$i" -lt 12 ] || exit 1; echo "dnf failed, retrying in 20 s ($i/12)" >&2; \
      dnf clean metadata >&2; sleep 20; \
    done
ENV HOME=/tmp CARGO_NET_RETRY=12
COPY bootguard/Cargo.toml bootguard/Cargo.lock /src/
COPY bootguard/src /src/src
RUN cd /src && cargo test --locked && cargo build --release --locked

FROM ${BASE} AS image
ARG VARIANT=base
ARG REPO_URL=https://github.com/ericcurtin/agenticlinux

COPY usr /usr
COPY packages.txt build.sh /tmp/
# mounted, not copied: the kernel RPMs would stay in a layer
RUN --mount=type=bind,from=kernel,target=/run/kernel VARIANT="$VARIANT" REPO_URL="$REPO_URL" /tmp/build.sh

COPY --from=bootguard /src/target/release/agenticlinux-bootguard /usr/bin/agenticlinux-bootguard
COPY bootguard/dist /
RUN systemctl enable agenticlinux-bootguard-boot.service \
                     agenticlinux-bootguard-check.service \
                     agenticlinux-bootguard-arm.service

RUN bootc container lint

FROM ${RECHUNKER} AS rechunk
ARG VARIANT=base
ARG VERSION=
RUN --mount=type=bind,from=image,target=/rootfs \
    --mount=type=bind,source=rechunk.sh,target=/tmp/rechunk.sh \
    VARIANT="$VARIANT" VERSION="$VERSION" /tmp/rechunk.sh

FROM scratch AS chunked
COPY --from=rechunk /out /

FROM image
