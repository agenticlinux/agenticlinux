#!/bin/bash
# The cloud-init qcow2 of one AgenticLinux image, for vmmbox and any NoCloud host.
# A full disk is 8-10 GB and a release asset 2 GiB at most, so it is small, like the
# ISO: the distribution's bootc image with cloud-init (cloud/Dockerfile), which
# stages the image once cloud-init is done. Run from the repository root with Docker
# and qemu-img.
#
# Usage: cloud/build.sh <image-ref> <bootc-image> <output.qcow2>
set -euxo pipefail

image=$1
bootc=$2
out=$3

trap 'rm -rf disk.raw oci convert.qcow2' EXIT
for i in 1 2 3; do
  docker build -f cloud/Dockerfile --build-arg BOOTC="$bootc" --build-arg IMAGE="$image" -t agenticlinux:cloud . && break
  [ "$i" -lt 3 ] || exit 1
  sleep 20
done
# The disk is sparse, and vmmbox grows it; sshd is started for whoever seeds a key
./install-disk.sh agenticlinux:cloud "$bootc" "$bootc" 32G disk.raw --karg systemd.wants=sshd.service
qemu-img convert -c -O qcow2 disk.raw convert.qcow2
mv convert.qcow2 "$out"
