#!/bin/bash
# Builds Fedora's newest kernel for aarch64 with 64 KiB pages into /out as the
# kernel-64k, -core, -modules, -modules-core, -modules-extra, -devel and
# -devel-matched RPMs. Fedora's kernel.spec has the variant but forces it off
# (RHEL ships it), and has no config for it: the 64k one is Fedora's aarch64
# config with the page size changed and olddefconfig run on it.
set -euxo pipefail

export HOME=/tmp
retry() {
  local i
  for i in $(seq 12); do
    "$@" && return
    echo "${*:1:2} failed ($i/12)" >&2
    [ "$i" -lt 12 ] && sleep 20
  done
  return 1
}

[ "$(uname -m)" = aarch64 ] || { echo "kernel-64k is aarch64 only" >&2; exit 1; }
retry dnf -y install rpm-build rpmdevtools python3 'dnf5-command(builddep)'

# KERNEL_NVR (7.2.15-300.fc45), else the newest kernel in the repositories, from
# the build system as build.sh fetches kernel-devel: mirrors lag it, and the
# source package is not in them.
if [ -n "${KERNEL_NVR:-}" ]; then
  v=${KERNEL_NVR%%-*} r=${KERNEL_NVR#*-}
else
  read -r v r < <(dnf -q repoquery --latest-limit=1 --qf '%{version} %{release}\n' kernel)
fi
srpm=kernel-$v-$r.src.rpm
retry curl -fsSL --retry 12 -o "/tmp/$srpm" \
  "https://kojipkgs.fedoraproject.org/packages/kernel/$v/$r/src/$srpm"
rpm -ivh "/tmp/$srpm"
cd "$HOME/rpmbuild"
retry dnf -y builddep SPECS/kernel.spec

# Enable the variant: the Fedora block turns it off before the %if that reads it.
python3 - <<'PY'
import re
p = "SPECS/kernel.spec"
s = open(p).read()
marker = "%if %{with_arm64_64k} && %{with_base}\n"
assert s.count(marker) == 1, "kernel.spec has changed: no single with_arm64_64k_base"
s = s.replace(marker, "%ifarch aarch64\n%define with_arm64_64k 1\n%endif\n" + marker)
open(p, "w").write(s)
PY

# The config: Fedora's aarch64 one with what makes its RT kernel's 64k variant
# differ from the RT one, which is only page-size options.
python3 - <<'PY'
import re
def load(path):
    options = {}
    for line in open("SOURCES/" + path):
        m = re.match(r"(?:# )?(CONFIG_\w+)(?:=| is not set)", line)
        if m:
            options[m.group(1)] = line.rstrip("\n")
    return options
rt, rt64k = load("kernel-aarch64-rt-fedora.config"), load("kernel-aarch64-rt-64k-fedora.config")
config = load("kernel-aarch64-fedora.config")
delta = [k for k in rt.keys() | rt64k.keys() if rt.get(k) != rt64k.get(k)]
assert "CONFIG_ARM64_64K_PAGES" in delta and len(delta) < 20, delta
for k in delta:
    if k in rt64k:
        config[k] = rt64k[k]
    else:
        config.pop(k, None)
assert config["CONFIG_ARM64_64K_PAGES"] == "CONFIG_ARM64_64K_PAGES=y"
assert config["CONFIG_ARM64_4K_PAGES"].startswith("# ")
for name in ("kernel-aarch64-64k-fedora.config", "kernel-aarch64-64k-debug-fedora.config"):
    with open("SOURCES/" + name, "w") as f:
        f.write("# arm64\n")
        f.writelines(config[k] + "\n" for k in sorted(config))
PY

# The build writes the kernel's FIPS checksum with sha512hmac, which asks the
# running kernel for hmac(sha512) over AF_ALG: a container's host may not offer
# it. Same output, from openssl, with the key libkcapi's tools use.
cat > /usr/local/bin/sha512hmac <<'SH'
#!/bin/sh
for f; do
  printf '%s  %s\n' "$(openssl dgst -sha512 -hmac orboDeJITITejsirpADONivirpUkvarP -r "$f" | cut -d' ' -f1)" "$f"
done
SH
chmod +x /usr/local/bin/sha512hmac

# Only the 64k kernel: no debug or stock kernel, tools or docs.
rpmbuild -bb SPECS/kernel.spec --target aarch64 \
  --without stock --without debug --without debuginfo --without doc \
  --without headers --without cross_headers --without perf --without tools \
  --without bpftool --without selftests --without efiuki --without configchecks \
  --without ipaclones
mkdir -p /out
cp RPMS/aarch64/kernel-64k-*.rpm /out/
ls -l /out
