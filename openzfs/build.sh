#!/usr/bin/env bash
# ================================================================
#  openzfs — kmod + utils build script
#  kmods-zodium : github.com/zodium-project/kmods-zodium
# ================================================================

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

say()  { printf "$@"; printf '\n'; }
info() { say "${CYAN}◈${NC}  $*"; }
ok()   { say "${GREEN}◆${NC}  $*"; }
warn() { say "${YELLOW}◇${NC}  $*"; }
fail() { say "${RED}⦻${NC}  $*" >&2; exit 1; }

cleanup() {
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◈  openzfs kmod + utils build          ║${NC}"
say "${MAGENTA}${BOLD}║   kmods-zodium                           ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""

mkdir -p /var/tmp
chmod 1777 /var/tmp

# ── Upgrade system ────────────────────────────────────────────
info "Upgrading system packages..."
dnf upgrade -y
ok "System upgraded"

# ── Detect kernel version ─────────────────────────────────────
info "Detecting latest kernel version..."
# KERNEL_NAME allows future flexibility for non-stock kernels
# defaults to 'kernel' for stock Fedora
KERNEL_NAME="${KERNEL_NAME:-kernel}"
KERNEL_VERSION="$(rpm -q "${KERNEL_NAME}" \
    --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort -V | tail -1)"
[[ -n "$KERNEL_VERSION" ]] || fail "Could not detect kernel version"
ok "Kernel: ${KERNEL_NAME} — ${KERNEL_VERSION}"

KERNEL_SRC="/usr/src/kernels/${KERNEL_VERSION}"

# ── Install build dependencies ────────────────────────────────
info "Installing build dependencies..."
if [[ "${KERNEL_NAME}" == "kernel" ]]; then
    KERNEL_DEVEL_PKG="kernel-devel-matched-${KERNEL_VERSION}"
else
    KERNEL_DEVEL_PKG="${KERNEL_NAME}-devel-${KERNEL_VERSION}"
fi

dnf install -y --setopt=install_weak_deps=False \
    "${KERNEL_DEVEL_PKG}" \
    gcc \
    make \
    autoconf \
    automake \
    libtool \
    rpm-build \
    curl \
    jq \
    gnupg2 \
    libtirpc-devel \
    libblkid-devel \
    libuuid-devel \
    libudev-devel \
    openssl-devel \
    zlib-ng-compat-devel \
    libaio-devel \
    libattr-devel \
    libffi-devel \
    libunwind-devel \
    libcurl-devel \
    elfutils-libelf-devel \
    python3-devel \
    python3-setuptools \
    python3-cffi \
    ncompress
ok "Build dependencies installed"

# ── Verify kernel headers ─────────────────────────────────────
info "Verifying kernel headers..."
[[ -d "$KERNEL_SRC" ]] || fail "Kernel headers missing at ${KERNEL_SRC}"
ok "Kernel headers: OK"

# ── Resolve ZFS version ───────────────────────────────────────
ZFS_MINOR_VERSION="${ZFS_MINOR_VERSION:-}"

# isolated workdir — avoids /tmp collisions on repeated runs
WORK_DIR="$(mktemp -d)"
cd "$WORK_DIR"

info "Fetching ZFS release list..."
curl -fLsS \
    -H "User-Agent: kmods-zodium" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/openzfs/zfs/releases" \
    -o zfs-releases.json

if [[ -n "${ZFS_MINOR_VERSION}" ]]; then
    ZFS_VERSION="$(jq -r \
        --arg ZMV "zfs-${ZFS_MINOR_VERSION}" \
        '[ .[] | select(.prerelease==false and .draft==false)
               | select(.tag_name | startswith($ZMV))
        ][0].tag_name' \
        zfs-releases.json | cut -f2- -d-)"
else
    ZFS_VERSION="$(jq -r \
        '[ .[] | select(.prerelease==false and .draft==false)
        ][0].tag_name' \
        zfs-releases.json | cut -f2- -d-)"
fi

[[ -n "$ZFS_VERSION" && "$ZFS_VERSION" != "null" ]] \
    || fail "Could not resolve ZFS version"
ok "ZFS version: ${ZFS_VERSION}"

# ── Download tarball + signatures ─────────────────────────────
BASE_URL="https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}"

info "Downloading zfs-${ZFS_VERSION}.tar.gz..."
curl -fLsS -O "${BASE_URL}/zfs-${ZFS_VERSION}.tar.gz"
curl -fLsS -O "${BASE_URL}/zfs-${ZFS_VERSION}.tar.gz.asc"
curl -fLsS -O "${BASE_URL}/zfs-${ZFS_VERSION}.sha256.asc"
ok "Tarball and signatures downloaded"

# ── GPG verification ──────────────────────────────────────────
info "Setting up GPG..."
mkdir -p /root/.gnupg
chmod 700 /root/.gnupg

info "Importing OpenZFS signing keys..."
gpg --yes --keyserver keyserver.ubuntu.com --recv D4598027
gpg --yes --keyserver keyserver.ubuntu.com --recv C77B9667
gpg --yes --keyserver keyserver.ubuntu.com --recv C6AF658B
ok "Signing keys imported"

info "Verifying tarball signature..."
gpg --verify "zfs-${ZFS_VERSION}.tar.gz.asc" "zfs-${ZFS_VERSION}.tar.gz" \
    || fail "Tarball signature verification FAILED"
ok "Tarball signature: OK"

info "Verifying checksum signature..."
gpg --verify "zfs-${ZFS_VERSION}.sha256.asc" \
    || fail "Checksum signature verification FAILED"
ok "Checksum signature: OK"

info "Verifying checksum..."
gpg --decrypt "zfs-${ZFS_VERSION}.sha256.asc" | sha256sum -c \
    || fail "Checksum verification FAILED"
ok "Checksum: OK"

# ── Extract source ────────────────────────────────────────────
info "Extracting zfs-${ZFS_VERSION}.tar.gz..."
tar -z -x --no-same-owner --no-same-permissions \
    -f "zfs-${ZFS_VERSION}.tar.gz"

ZFS_SRC="${WORK_DIR}/zfs-${ZFS_VERSION}"
[[ -d "$ZFS_SRC" ]] || fail "Source directory not found after extraction"
ok "Source extracted: ${ZFS_SRC}"

# ── Patch spec kernel-devel dep for non-stock kernels ─────────
# ensures rpm spec depends on correct kernel-devel package
# e.g. kernel-longterm-devel instead of kernel-devel
if [[ "${KERNEL_NAME}" != "kernel" ]]; then
    info "Patching spec files for kernel name: ${KERNEL_NAME}..."
    sed -i "s|kernel-devel|${KERNEL_NAME}-devel|g" \
        "${ZFS_SRC}"/rpm/*/*spec.in
    ok "Spec files patched"
fi

# ── Configure ─────────────────────────────────────────────────
info "Configuring for kernel ${KERNEL_VERSION}..."
cd "$ZFS_SRC"
if ! ./configure \
        --with-linux="${KERNEL_SRC}" \
        --with-linux-obj="${KERNEL_SRC}" \
        --enable-systemd; then
    [[ -f config.log ]] && cat config.log
    fail "configure failed"
fi
ok "Configure complete"

# ── Build RPMs ────────────────────────────────────────────────
info "Building RPMs..."
if ! make -j"$(nproc)" rpm-utils rpm-kmod; then
    [[ -f config.log ]] && cat config.log
    fail "Build failed"
fi
ok "RPMs built"

# ── Collect RPMs ──────────────────────────────────────────────
info "Collecting built RPMs..."

ALL_RPMS=()
while IFS= read -r -d '' rpm; do
    base="$(basename "$rpm")"
    [[ "$base" == *debuginfo* ]]  && continue
    [[ "$base" == *debugsource* ]] && continue
    [[ "$base" == *-devel-* ]]    && continue
    [[ "$base" == *dkms* ]]       && continue
    [[ "$base" == *test* ]]       && continue
    [[ "$base" == *.src.rpm ]]    && continue
    ALL_RPMS+=("$rpm")
done < <(find "${ZFS_SRC}" /root/rpmbuild/RPMS \
    -name "*.rpm" -print0 2>/dev/null)

[[ ${#ALL_RPMS[@]} -gt 0 ]] || fail "No RPMs collected"

ok "Collected ${#ALL_RPMS[@]} RPMs:"
for rpm in "${ALL_RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Verify runtime package set ────────────────────────────────
info "Verifying runtime package set..."

check_pkg() {
    local pattern="$1" label="$2"
    for rpm in "${ALL_RPMS[@]}"; do
        [[ "$(basename "$rpm")" == ${pattern} ]] && return 0
    done
    fail "${label} not found in collected RPMs"
}

check_pkg "kmod-zfs-*"      "kmod-zfs (kernel module)"
check_pkg "zfs-[0-9]*"      "zfs (CLI tools)"
check_pkg "zfs-dracut-*"    "zfs-dracut (initrd hook)"
check_pkg "libnvpair[0-9]*" "libnvpair (runtime lib)"
check_pkg "libuutil[0-9]*"  "libuutil (runtime lib)"
check_pkg "libzfs[0-9]*"    "libzfs (runtime lib)"
check_pkg "libzpool[0-9]*"  "libzpool (runtime lib)"

ok "All runtime packages verified"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${ALL_RPMS[@]}" /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  openzfs build complete              ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""