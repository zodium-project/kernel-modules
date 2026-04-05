#!/usr/bin/env bash
# ================================================================
#  v4l2loopback — kmod build script
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
say "${MAGENTA}${BOLD}║   ◈  v4l2loopback kmod build             ║${NC}"
say "${MAGENTA}${BOLD}║   kmods-zodium                           ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════╝${NC}"
say ""

# ── Detect kernel version ─────────────────────────────────────
info "Detecting latest kernel version..."
KERNEL_VERSION="$(rpm -q kernel \
    --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
    | sort -V | tail -1)"
[[ -n "$KERNEL_VERSION" ]] || fail "Could not detect kernel version"
ok "Kernel version: ${KERNEL_VERSION}"

# ── Detect kmod version ───────────────────────────────────────
info "Detecting latest v4l2loopback release tag..."
V4L2LB_TAG="$(curl -fLsS \
    https://api.github.com/repos/v4l2loopback/v4l2loopback/tags \
    | grep '"name"' | head -1 | cut -d'"' -f4)"
[[ -n "$V4L2LB_TAG" ]] || fail "Could not detect latest v4l2loopback tag"

# strip leading v for RPM version field
V4L2LB_VERSION="${V4L2LB_TAG#v}"
ok "v4l2loopback tag: ${V4L2LB_TAG} → RPM version: ${V4L2LB_VERSION}"

# ── Install build dependencies ────────────────────────────────
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False \
    kernel-devel-${KERNEL_VERSION} \
    gcc \
    make \
    rpm-build \
    git \
    help2man \
    perl
ok "Build dependencies installed"

# ── Setup rpmbuild dirs ───────────────────────────────────────
info "Setting up rpmbuild directories..."
mkdir -p /root/rpmbuild/BUILD \
          /root/rpmbuild/RPMS \
          /root/rpmbuild/SOURCES \
          /root/rpmbuild/SPECS \
          /root/rpmbuild/SRPMS
ok "rpmbuild directories ready"

# ── Clone v4l2loopback source at latest release tag ───────────
info "Cloning v4l2loopback ${V4L2LB_TAG}..."
git clone --depth=1 --branch "${V4L2LB_TAG}" \
    https://github.com/v4l2loopback/v4l2loopback.git \
    /root/rpmbuild/BUILD/v4l2loopback-${V4L2LB_VERSION}
ok "Source cloned"

# ── Create source tarball ─────────────────────────────────────
info "Creating source tarball..."
tar -czf /root/rpmbuild/SOURCES/v4l2loopback-${V4L2LB_VERSION}.tar.gz \
    -C /root/rpmbuild/BUILD v4l2loopback-${V4L2LB_VERSION}
ok "Source tarball created: v4l2loopback-${V4L2LB_VERSION}.tar.gz"

# ── Copy spec ─────────────────────────────────────────────────
info "Copying spec file..."
cp /kmods-zodium/v4l2loopback/v4l2loopback.spec /root/rpmbuild/SPECS/
ok "Spec file copied"

# ── Build RPMs ────────────────────────────────────────────────
info "Building RPMs..."
rpmbuild -bb /root/rpmbuild/SPECS/v4l2loopback.spec \
    --define "kernel_version ${KERNEL_VERSION}" \
    --define "kmod_version ${V4L2LB_VERSION}"
ok "RPMs built"

# ── Verify & list built RPMs ──────────────────────────────────
info "Verifying built RPMs..."
RPMS=("$(find /root/rpmbuild/RPMS -name '*.rpm')")
[[ ${#RPMS[@]} -gt 0 ]] || fail "No RPMs found after build"

ok "Built RPMs:"
for rpm in /root/rpmbuild/RPMS/**/*.rpm; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp /root/rpmbuild/RPMS/**/*.rpm /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  v4l2loopback build complete                 ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""