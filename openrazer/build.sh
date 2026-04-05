#!/usr/bin/env bash
# ================================================================
#  openrazer — kmod build script
#  kmods-zodium : github.com/zodium-project/kmods-zodium
# ================================================================

set -Eeuo pipefail

# ── Styling ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

say()  { printf "$@"; printf '\n'; }
info() { say "${CYAN}◈${NC}  $*"; }
ok()   { say "${GREEN}◆${NC}  $*"; }
warn() { say "${YELLOW}◇${NC}  $*"; }
fail() { say "${RED}⦻${NC}  $*" >&2; exit 1; }

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◈  openrazer kmod build                ║${NC}"
say "${MAGENTA}${BOLD}║   kmods-zodium                           ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""

# ── Paths ─────────────────────────────────────────────────────
BUILDROOT="/kmods-zodium/rpmbuild"

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

# ── Detect openrazer version ──────────────────────────────────
info "Detecting latest openrazer release..."
OPENRAZER_TAG="$(curl -fLsS \
    https://api.github.com/repos/openrazer/openrazer/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)"
[[ -n "$OPENRAZER_TAG" ]] || fail "Could not detect latest openrazer release"

# strip leading v for RPM version field
OPENRAZER_VERSION="${OPENRAZER_TAG#v}"
ok "openrazer tag: ${OPENRAZER_TAG} → RPM version: ${OPENRAZER_VERSION}"

# ── Install build dependencies ────────────────────────────────
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False \
    "kernel-devel-matched-$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | sort -V | tail -1)" \
    gcc \
    make \
    rpm-build \
    git \
    python3 \
    python3-setuptools \
    python3-dbus \
    python3-gobject \
    python3-pyudev \
    python3-daemonize \
    python3-setproctitle
ok "Build dependencies installed"

# ── Setup rpmbuild dirs ───────────────────────────────────────
info "Setting up rpmbuild directories..."
mkdir -p "${BUILDROOT}/BUILD" \
         "${BUILDROOT}/RPMS" \
         "${BUILDROOT}/SOURCES" \
         "${BUILDROOT}/SPECS" \
         "${BUILDROOT}/SRPMS"
ok "rpmbuild directories ready"

# ── Clone openrazer source at latest release tag ──────────────
info "Cloning openrazer ${OPENRAZER_TAG}..."
git clone --depth=1 --branch "${OPENRAZER_TAG}" \
    https://github.com/openrazer/openrazer.git \
    "${BUILDROOT}/BUILD/openrazer-${OPENRAZER_VERSION}"
ok "Source cloned"

# ── Create source tarball ─────────────────────────────────────
info "Creating source tarball..."
tar -czf "${BUILDROOT}/SOURCES/openrazer-${OPENRAZER_VERSION}.tar.gz" \
    -C "${BUILDROOT}/BUILD" openrazer-${OPENRAZER_VERSION}
ok "Source tarball created: openrazer-${OPENRAZER_VERSION}.tar.gz"

# ── Copy spec ─────────────────────────────────────────────────
info "Copying spec file..."
cp /kmods-zodium/openrazer/openrazer.spec "${BUILDROOT}/SPECS/"
ok "Spec file copied"

# ── Build RPMs ────────────────────────────────────────────────
info "Building RPMs..."
rpmbuild -bb "${BUILDROOT}/SPECS/openrazer.spec" \
    --define "_topdir ${BUILDROOT}" \
    --define "kernel_version ${KERNEL_VERSION}" \
    --define "kmod_version ${OPENRAZER_VERSION}"
ok "RPMs built"

# ── Verify & list built RPMs ──────────────────────────────────
info "Verifying built RPMs..."
shopt -s globstar
RPMS=("${BUILDROOT}"/RPMS/**/*.rpm)
[[ ${#RPMS[@]} -gt 0 ]] || fail "No RPMs found after build"

ok "Built RPMs:"
for rpm in "${RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

# ── Cleanup ───────────────────────────────────────────────────
info "Cleaning up build directory..."
rm -rf "${BUILDROOT}"
ok "Cleanup complete"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  openrazer build complete                    ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""