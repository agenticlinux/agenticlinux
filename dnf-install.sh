#!/bin/sh
# dnf install with 12 tries, 20 s apart, and fresh metadata for each: stale
# metadata fails the same way every time. For the Dockerfile's build stages.
for i in $(seq 12); do
  dnf install -y "$@" && exit 0
  [ "$i" -lt 12 ] || exit 1
  echo "dnf failed, retrying in 20 s ($i/12)" >&2
  dnf clean metadata >&2
  sleep 20
done
