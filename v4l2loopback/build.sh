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
    "kernel-devel-matched-$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | sort -V | tail -1)" \
    gcc \
    make \
    rpm-build \
    git \
    help2man \
    perl \
    rpmrebuild
ok "Build dependencies installed"

# ── Setup rpmbuild dirs ───────────────────────────────────────
info "Setting up rpmbuild directories..."
mkdir -p "${BUILDROOT}/BUILD" \
         "${BUILDROOT}/RPMS" \
         "${BUILDROOT}/SOURCES" \
         "${BUILDROOT}/SPECS" \
         "${BUILDROOT}/SRPMS"
ok "rpmbuild directories ready"

# ── Clone v4l2loopback source at latest tag ───────────────────
info "Cloning v4l2loopback ${V4L2LB_TAG}..."
git clone --depth=1 --branch "${V4L2LB_TAG}" \
    https://github.com/v4l2loopback/v4l2loopback.git \
    "${BUILDROOT}/BUILD/v4l2loopback-${V4L2LB_VERSION}"
ok "Source cloned"

# ── Create source tarball ─────────────────────────────────────
info "Creating source tarball..."
tar -czf "${BUILDROOT}/SOURCES/v4l2loopback-${V4L2LB_VERSION}.tar.gz" \
    -C "${BUILDROOT}/BUILD" v4l2loopback-${V4L2LB_VERSION}
ok "Source tarball created: v4l2loopback-${V4L2LB_VERSION}.tar.gz"

# ── Copy spec ─────────────────────────────────────────────────
info "Copying spec file..."
cp /kmods-zodium/v4l2loopback/v4l2loopback.spec "${BUILDROOT}/SPECS/"
ok "Spec file copied"

# ── Install signing keys ──────────────────────────────────────
info "Installing signing keys for Secure Boot..."
[[ -n "${ZODIUM_MOK_KEY:-}" ]] || fail "ZODIUM_MOK_KEY env var not set"
[[ -f /zodium-mok.der ]] || fail "/zodium-mok.der not found"
mkdir -p /tmp/zodium-sign
printf '%s\n' "${ZODIUM_MOK_KEY}" > /tmp/zodium-sign/private_key.priv
chmod 600 /tmp/zodium-sign/private_key.priv
cp /zodium-mok.der /tmp/zodium-sign/public_key.der
ok "Signing keys installed"

# ── Build RPMs ────────────────────────────────────────────────
info "Building RPMs..."
rpmbuild -bb "${BUILDROOT}/SPECS/v4l2loopback.spec" \
    --define "_topdir ${BUILDROOT}" \
    --define "kernel_version ${KERNEL_VERSION}" \
    --define "kmod_version ${V4L2LB_VERSION}"
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

# ── Install kmod RPM, sign modules, repack ───────────────────
info "Installing kmod RPM for signing..."
KMOD_RPM="$(printf '%s\n' "${RPMS[@]}" | grep 'kmod-v4l2loopback-' | head -1)"
[[ -n "${KMOD_RPM}" ]] || fail "kmod RPM not found"
dnf install -y "${KMOD_RPM}"
ok "kmod RPM installed"

info "Signing v4l2loopback modules..."
SIGN_FILE="/usr/src/kernels/${KERNEL_VERSION}/scripts/sign-file"
[[ -x "${SIGN_FILE}" ]] || fail "sign-file not found: ${SIGN_FILE}"

for module in /usr/lib/modules/${KERNEL_VERSION}/extra/v4l2loopback/*.ko*; do
    if [[ "${module}" == *.xz ]]; then
        xz -d --rm "${module}"; module="${module%.xz}"
        "${SIGN_FILE}" sha256 /tmp/zodium-sign/private_key.priv /tmp/zodium-sign/public_key.der "${module}"
        xz -C crc32 -f "${module}"
    elif [[ "${module}" == *.zst ]]; then
        zstd -d --rm "${module}"; module="${module%.zst}"
        "${SIGN_FILE}" sha256 /tmp/zodium-sign/private_key.priv /tmp/zodium-sign/public_key.der "${module}"
        zstd -f --rm "${module}"
    else
        "${SIGN_FILE}" sha256 /tmp/zodium-sign/private_key.priv /tmp/zodium-sign/public_key.der "${module}"
    fi
    ok "Signed: $(basename "${module}")"
done
ok "Modules signed"

info "Repacking kmod RPM with signed modules..."
REBUILT_DIR="${BUILDROOT}/rebuilt"
mkdir -p "${REBUILT_DIR}"
KMOD_PKG="$(rpm -q --queryformat '%{NAME}' "kmod-v4l2loopback-${KERNEL_VERSION}" 2>/dev/null | head -1)"
[[ -n "${KMOD_PKG}" ]] || fail "kmod package not found in RPM DB"
RPMREBUILD_TMPDIR="${REBUILT_DIR}/tmp"
mkdir -p "${RPMREBUILD_TMPDIR}"
HOME="${RPMREBUILD_TMPDIR}" rpmrebuild --batch -d "${REBUILT_DIR}" "${KMOD_PKG}"
mapfile -t REBUILT < <(find "${REBUILT_DIR}" -name 'kmod-v4l2loopback-*.rpm')
[[ ${#REBUILT[@]} -gt 0 ]] || fail "rpmrebuild produced no RPM"
mv -f "${REBUILT[0]}" "${KMOD_RPM}"
ok "kmod RPM repacked"

# ── Verify module signatures ──────────────────────────────────
info "Verifying module signatures..."
for rpm in "${RPMS[@]}"; do
    VERIFY_DIR="$(mktemp -d)"
    pushd "${VERIFY_DIR}" > /dev/null
    rpm2cpio "${rpm}" | cpio -idm --quiet

    while IFS= read -r -d '' mod; do
        if [[ "${mod}" == *.xz ]]; then
            xz -dc "${mod}" > "${mod%.xz}"
            mod="${mod%.xz}"
        elif [[ "${mod}" == *.zst ]]; then
            zstd -dc "${mod}" > "${mod%.zst}"
            mod="${mod%.zst}"
        fi
        signer="$(modinfo -F signer "${mod}" 2>/dev/null || true)"
        [[ -n "${signer}" ]] \
            || fail "Unsigned module found in $(basename "${rpm}"): $(basename "${mod}")"
        ok "Signed by '${signer}': $(basename "${mod}")"
    done < <(find . -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print0)

    popd > /dev/null
    rm -rf "${VERIFY_DIR}"
done
ok "All modules verified signed"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

# ── Cleanup ───────────────────────────────────────────────────
info "Cleaning up build directory..."
rm -rf "${BUILDROOT}" /tmp/zodium-sign
ok "Cleanup complete"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  v4l2loopback build complete                 ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""