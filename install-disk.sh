#!/bin/bash
# Install a local Docker image into a sparse raw disk with bootc, from the
# image's OCI layout, through a loop device. No qemu-nbd: with it the kernel's
# writeback of the target filesystem waits on a userspace process that is itself
# writing to the host's disk, and the install has hung there (gnome, 57 minutes
# in a step that takes 8-15, until the runner stopped answering). The loop
# driver does that writeback inside the kernel. Run from the repository root
# with Docker; oci/ and the disk are left to the caller.
#
# Usage: install-disk.sh <image> <bootc-image> <target-imgref> <size> <disk.raw> [karg options...]
set -euxo pipefail

image=$1
bootc=$2
target=$3
size=$4
disk=$5
shift 5

rm -rf oci
mkdir oci
docker save "$image" | tar x -C oci
# The image is in oci now. Everything Docker still holds (the image, its
# unpacked snapshots, the build's cache) shares the disk with the raw file,
# which grows by the whole installed system as bootc writes it.
docker system prune -af
df -h /
# Patient retries, as in build.sh: quay.io has answered 502 mid-pull, and docker
# run's own implicit pull is a single attempt. The installer is the
# distribution's own bootc image.
for i in $(seq 12); do docker pull "$bootc" && break || sleep 20; done

# no_timer_check: the kernel's IO-APIC timer sanity test wants five PIT ticks
# within a short delay run before the TSC is calibrated, and a loaded HVF host
# has missed that and panicked 16 ms into boot (the kernel skips the test itself
# on every hypervisor it recognizes, KVM, Hyper-V and VMware, but sees HVF as
# bare metal).
# nousershstk: some Azure hosts' Hyper-V advertises CET shadow stacks in CPUID
# under WHPX but no XSAVES support for their state. The kernel (6.12 at least)
# enables user shadow stacks on the CPUID bit alone, glibc turns them on for the
# first CET-marked daemon, and the CET MSRs, no longer part of the saved state,
# are never switched: every later task on that vCPU ran on fwupd's shadow stack
# and segfaulted, llama-server and journald included, and the test hung until
# the host's two-hour timeout (centos-kde, Windows).
install_disk() {
  rm -f "$disk"
  truncate -s "$size" "$disk"
  local status=0
  # docker run passes timeout's SIGTERM on to bootc; a container that outlives
  # it is removed below
  timeout -k 2m 30m docker run --rm --name bootc-install --privileged --pid=host \
    -v /dev:/dev -v "$PWD/oci:/oci:ro" -v "$PWD/$disk:/disk.raw" \
    -v "$PWD/usr/lib/bootc/install:/usr/lib/bootc/install:ro" \
    "$bootc" \
    bootc install to-disk --via-loopback --source-imgref oci:/oci \
    --target-imgref "$target" --generic-image --skip-fetch-check \
    --karg console=ttyS0 --karg console=ttyAMA0 --karg no_timer_check --karg nousershstk \
    "$@" /disk.raw || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -ne 124 ] || echo "the install did not finish within 30 minutes"
    docker rm -f bootc-install >/dev/null 2>&1 || true
    # What the failure looked like from each side of the loop device: the
    # host's disk, the kernel's view of loop and xfs (and of any task stuck on
    # them), and how full the target filesystem actually was
    df -h /
    sudo dmesg | grep -iE 'loop|xfs|i/o error|blocked for more' | tail -n 30 || true
    for dev in $(sudo losetup --list -n -O NAME -j "$disk"); do
      sudo losetup -d "$dev" || true
    done
    if dev=$(sudo losetup -P --find --show "$disk"); then
      sudo mkdir -p /mnt/target
      sudo mount -o ro,norecovery "${dev}p3" /mnt/target && df -h /mnt/target &&
        sudo umount /mnt/target || true
      sudo losetup -d "$dev" || true
    fi
  fi
  return "$status"
}
# The install has failed with "No space left on device" from the target
# filesystem four minutes in, for an image that installs into well under half of
# the 60 GB disk, while the same step passed for larger variants in the same run
# and for the same variant in the runs around it. Nothing about it is
# deterministic, so a failed or timed-out install is retried once on a fresh disk
# after the diagnostics.
install_disk "$@" || install_disk "$@"
