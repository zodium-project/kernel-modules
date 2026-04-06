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
KERNEL_VERSION="$(rpm -q kernel \
    --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort -V | tail -1)"
[[ -n "$KERNEL_VERSION" ]] || fail "Could not detect kernel version"
ok "Kernel version: ${KERNEL_VERSION}"

KERNEL_SRC="/usr/src/kernels/${KERNEL_VERSION}"

# ── Install dnf5 plugins ──────────────────────────────────────
info "Installing dnf5 plugins..."
dnf install -y --setopt=install_weak_deps=False dnf5-plugins
ok "dnf5 plugins installed"

# ── Add zfsonlinux repo ───────────────────────────────────────
info "Adding zfsonlinux repo..."
FEDORA_VER="$(rpm -E %fedora)"
dnf install -y --setopt=install_weak_deps=False \
    "https://zfsonlinux.org/fedora/zfs-release-2-4$(rpm --eval '%{dist}').noarch.rpm"

# Use zfs-legacy for stability (more real-world testing than zfs-latest)
dnf config-manager setopt "zfs*.enabled=0"
dnf config-manager setopt "zfs-legacy.enabled=1"
dnf --refresh makecache
ok "zfsonlinux zfs-legacy repo enabled"

# ── Install build dependencies ────────────────────────────────
info "Installing build dependencies for kernel: ${KERNEL_VERSION}..."
dnf install -y --setopt=install_weak_deps=False \
    "kernel-devel-matched-$(rpm -q kernel \
        --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | sort -V | tail -1)" \
    gcc \
    make \
    autoconf \
    automake \
    libtool \
    rpm-build \
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
    elfutils-libelf-devel \
    python3-devel \
    python3-setuptools \
    python3-cffi \
    ncompress
ok "Build dependencies installed"

# ── Verify kernel headers are present ─────────────────────────
info "Verifying kernel headers..."
[[ -d "$KERNEL_SRC" ]] || \
    fail "Kernel headers missing at ${KERNEL_SRC}"
ok "Kernel headers: OK"

# ── Get ZFS source via SRPM ───────────────────────────────────
# Installing the SRPM is the cleanest way to get the exact versioned
# source tarball that matches the legacy repo, without hardcoding versions.
info "Installing zfs SRPM to obtain source tarball..."
SRPM_DIR="$(mktemp -d)"
dnf download --source --destdir="${SRPM_DIR}" zfs
SRPM="$(ls "${SRPM_DIR}"/zfs-*.src.rpm | sort -V | tail -1)"
[[ -n "$SRPM" ]] || fail "Failed to download zfs SRPM"
ok "SRPM: $(basename "$SRPM")"

# Extract ZFS version from SRPM name: zfs-2.2.7-1.fc42.src.rpm → 2.2.7
ZFS_VERSION="$(basename "$SRPM" | grep -oP '(?<=zfs-)\d+\.\d+\.\d+')"
[[ -n "$ZFS_VERSION" ]] || fail "Could not parse ZFS version from SRPM"
ok "ZFS version: ${ZFS_VERSION}"

# Install SRPM to get the source tarball into rpmbuild tree
rpm -ivh "$SRPM" 2>/dev/null || true
TARBALL="${HOME}/rpmbuild/SOURCES/zfs-${ZFS_VERSION}.tar.gz"
[[ -f "$TARBALL" ]] || fail "Source tarball not found at ${TARBALL}"
ok "Source tarball: zfs-${ZFS_VERSION}.tar.gz"

# ── Extract and prepare source ────────────────────────────────
BUILD_DIR="$(mktemp -d)"
info "Extracting source to ${BUILD_DIR}..."
tar -xzf "$TARBALL" -C "$BUILD_DIR"
ZFS_SRC="${BUILD_DIR}/zfs-${ZFS_VERSION}"
[[ -d "$ZFS_SRC" ]] || fail "Source directory not found after extraction"
ok "Source extracted"

# ── Configure ─────────────────────────────────────────────────
info "Running autogen.sh..."
cd "$ZFS_SRC"
bash autogen.sh
ok "autogen complete"

info "Configuring for kernel ${KERNEL_VERSION}..."
./configure \
    --with-linux="${KERNEL_SRC}" \
    --with-linux-obj="${KERNEL_SRC}" \
    --enable-systemd
ok "Configure complete"

# ── Build RPMs ────────────────────────────────────────────────
info "Building kmod RPM (make -j$(nproc) rpm-kmod)..."
make -j"$(nproc)" rpm-kmod
ok "rpm-kmod built"

info "Building utils RPMs (make -j$(nproc) rpm-utils)..."
make -j"$(nproc)" rpm-utils
ok "rpm-utils built"

# ── Collect RPMs ──────────────────────────────────────────────
info "Collecting built RPMs..."

# rpm-kmod lands in the build dir itself
# rpm-utils lands in ~/rpmbuild/RPMS/{x86_64,noarch}
shopt -s nullglob
KMOD_RPMS=("${ZFS_SRC}"/*.x86_64.rpm)
UTIL_RPMS_ARCH=(${HOME}/rpmbuild/RPMS/x86_64/zfs-*.rpm
                ${HOME}/rpmbuild/RPMS/x86_64/lib*.rpm)
UTIL_RPMS_NOARCH=(${HOME}/rpmbuild/RPMS/noarch/zfs-dracut-*.rpm
                  ${HOME}/rpmbuild/RPMS/noarch/python3-pyzfs-*.rpm)
shopt -u nullglob

# Filter out debuginfo/debugsource — not needed in zcore
ALL_RPMS=()
for rpm in "${KMOD_RPMS[@]}" "${UTIL_RPMS_ARCH[@]}" "${UTIL_RPMS_NOARCH[@]}"; do
    [[ "$rpm" == *debuginfo* || "$rpm" == *debugsource* ]] && continue
    [[ "$rpm" == *devel* ]] && continue        # libzfs-devel not needed at runtime
    [[ "$rpm" == *dkms* ]] && continue         # definitely not
    ALL_RPMS+=("$rpm")
done

[[ ${#ALL_RPMS[@]} -gt 0 ]] || fail "No RPMs collected"

ok "Collected ${#ALL_RPMS[@]} RPMs:"
for rpm in "${ALL_RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# Verify kmod-zfs is in the set — it's the critical one
found_kmod=false
for rpm in "${ALL_RPMS[@]}"; do
    [[ "$(basename "$rpm")" == kmod-zfs-* ]] && { found_kmod=true; break; }
done
$found_kmod || fail "kmod-zfs RPM not found in collected set"

# Verify zfs-dracut is present — needed for initrd
found_dracut=false
for rpm in "${ALL_RPMS[@]}"; do
    [[ "$(basename "$rpm")" == zfs-dracut-* ]] && { found_dracut=true; break; }
done
$found_dracut || fail "zfs-dracut RPM not found — initrd hook would be missing"

ok "Critical packages verified: kmod-zfs ✓  zfs-dracut ✓"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${ALL_RPMS[@]}" /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  openzfs build complete              ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""