#!/usr/bin/env bash
# ================================================================
#  sc0710 — kmod build script
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
say "${MAGENTA}${BOLD}║   ◈  sc0710 kmod build                  ║${NC}"
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
    kernel-devel-matched-"${KERNEL_VERSION}" \
    akmods
ok "Build dependencies installed"

# ── Install signing keys for akmods ──────────────────────────
info "Installing signing keys for Secure Boot..."
[[ -n "${ZODIUM_MOK_KEY:-}" ]] || fail "ZODIUM_MOK_KEY env var not set"
[[ -f /zodium-mok.der ]] || fail "/zodium-mok.der not found"

mkdir -p /etc/pki/akmods/private /etc/pki/akmods/certs
chown root:akmods /etc/pki/akmods/private /etc/pki/akmods/certs
chmod 750 /etc/pki/akmods/private
chmod 755 /etc/pki/akmods/certs

printf '%s\n' "${ZODIUM_MOK_KEY}" > /etc/pki/akmods/private/private_key.priv
chown root:akmods /etc/pki/akmods/private/private_key.priv
chmod 640 /etc/pki/akmods/private/private_key.priv

cp /zodium-mok.der /etc/pki/akmods/certs/public_key.der
chown root:akmods /etc/pki/akmods/certs/public_key.der
chmod 640 /etc/pki/akmods/certs/public_key.der

ok "Signing keys installed"

# ── Patch akmodsbuild for container compatibility ─────────────
warn "Applying akmodsbuild container workaround..."
cp /usr/sbin/akmodsbuild /usr/sbin/akmodsbuild.backup
sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' /usr/sbin/akmodsbuild
ok "akmodsbuild patched"

# ── Install akmod source package ──────────────────────────────
info "Installing akmod-sc0710..."
dnf install -y --setopt=install_weak_deps=False akmod-sc0710
ok "akmod-sc0710 installed"

# ── Build kmod ────────────────────────────────────────────────
info "Building sc0710 kmod for ${KERNEL_VERSION}..."
akmods --force --kernels "${KERNEL_VERSION}" --kmod sc0710
ok "sc0710 kmod built"

# ── Restore akmodsbuild ───────────────────────────────────────
mv /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild
ok "akmodsbuild restored"

# ── Locate built RPM ──────────────────────────────────────────
info "Locating built sc0710 kmod RPM..."
shopt -s nullglob
RPMS=(/var/cache/akmods/sc0710/kmod-sc0710-*.rpm)
shopt -u nullglob

[[ ${#RPMS[@]} -gt 0 ]] || \
    (cat /var/cache/akmods/sc0710/*.failed.log 2>/dev/null; \
     fail "No sc0710 kmod RPM found in /var/cache/akmods/sc0710/")

ok "Built RPMs:"
for rpm in "${RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

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

# ── Download companion packages ───────────────────────────────
info "Downloading sc0710 companion packages..."
dnf download -y --destdir /output/ \
    sc0710
ok "Companion packages downloaded"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  sc0710 kmod build complete                 ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""