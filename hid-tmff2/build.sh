#!/usr/bin/env bash
# ================================================================
#  hid-tmff2 — kmod build script
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
say "${MAGENTA}${BOLD}║   ◈  hid-tmff2 kmod build                ║${NC}"
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

# ── Install dnf5 plugins ──────────────────────────────────────
info "Installing dnf5 plugins..."
dnf install -y --setopt=install_weak_deps=False dnf5-plugins
ok "dnf5 plugins installed"

# ── Add Terra repo ────────────────────────────────────────────
info "Adding Terra repo..."
dnf install --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release -y
dnf reinstall terra-release -y
dnf --refresh makecache
ok "Terra repo added"

# ── Install build deps ────────────────────────────────────────
info "Installing build dependencies for kernel: ${KERNEL_VERSION}..."
dnf install -y --setopt=install_weak_deps=False \
    "kernel-devel-matched-$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | sort -V | tail -1)" \
    akmods
ok "Build dependencies installed"

# ── Patch akmodsbuild for container compatibility ─────────────
warn "Applying akmodsbuild container workaround..."
cp /usr/sbin/akmodsbuild /usr/sbin/akmodsbuild.backup
sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' /usr/sbin/akmodsbuild
ok "akmodsbuild patched"

# ── Install akmod source package ──────────────────────────────
info "Installing akmod-hid-tmff2..."
dnf install -y --setopt=install_weak_deps=False akmod-hid-tmff2
ok "akmod-hid-tmff2 installed"

# ── Build kmod ────────────────────────────────────────────────
info "Building hid-tmff2 kmod for ${KERNEL_VERSION}..."
akmods --force --kernels "${KERNEL_VERSION}" --kmod hid-tmff2
ok "hid-tmff2 kmod built"

# ── Restore akmodsbuild ───────────────────────────────────────
mv /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
ok "akmodsbuild restored"

# ── Locate built RPM ──────────────────────────────────────────
info "Locating built hid-tmff2 kmod RPM..."
shopt -s nullglob
RPMS=(/var/cache/akmods/hid-tmff2/kmod-hid-tmff2-*.rpm)
shopt -u nullglob

[[ ${#RPMS[@]} -gt 0 ]] || \
    (cat /var/cache/akmods/hid-tmff2/*.failed.log 2>/dev/null; \
     fail "No hid-tmff2 kmod RPM found in /var/cache/akmods/hid-tmff2/")

ok "Built RPMs:"
for rpm in "${RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  hid-tmff2 kmod build complete               ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""