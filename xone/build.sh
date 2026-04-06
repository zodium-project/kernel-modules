#!/usr/bin/env bash
# ================================================================
#  xone — kmod build script
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

WORKDIR=""
AKMODSBUILD_BACKUP="/usr/sbin/akmodsbuild.backup"
cleanup() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    [[ -f "${AKMODSBUILD_BACKUP}" ]] && mv -f "${AKMODSBUILD_BACKUP}" /usr/sbin/akmodsbuild
}
trap cleanup EXIT

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◈  xone kmod build                     ║${NC}"
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

# ── Add negativo17 multimedia repo ────────────────────────────
info "Adding negativo17 multimedia repo..."
dnf config-manager addrepo \
    --from-repofile=https://negativo17.org/repos/fedora-multimedia.repo
dnf config-manager setopt fedora-multimedia.enabled=1
dnf config-manager setopt fedora-multimedia.priority=90
dnf --refresh makecache
ok "negativo17 multimedia repo added"

# ── Install build deps ────────────────────────────────────────
info "Installing build dependencies for kernel: ${KERNEL_VERSION}..."
dnf install -y --setopt=install_weak_deps=False \
    "kernel-devel-matched-$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' | sort -V | tail -1)" \
    akmods \
    rpmrebuild
ok "Build dependencies installed"

# ── Patch akmodsbuild for container compatibility ─────────────
warn "Applying akmodsbuild container workaround..."
cp /usr/sbin/akmodsbuild "${AKMODSBUILD_BACKUP}"
sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' /usr/sbin/akmodsbuild
ok "akmodsbuild patched"

# ── Install akmod source package ──────────────────────────────
info "Installing akmod-xone..."
dnf install -y --setopt=install_weak_deps=False akmod-xone
ok "akmod-xone installed"

# ── Build kmod ────────────────────────────────────────────────
info "Building xone kmod for ${KERNEL_VERSION}..."
akmods --force --kernels "${KERNEL_VERSION}" --kmod xone
ok "xone kmod built"

# ── Restore akmodsbuild ───────────────────────────────────────
ok "akmodsbuild will be restored on exit via trap"

# ── Sign kmod modules & repack RPM ────────────────────────────
info "Signing xone kmod modules..."
SIGN_FILE="/usr/src/kernels/${KERNEL_VERSION}/scripts/sign-file"
[[ -x "$SIGN_FILE" ]] || fail "sign-file not found: ${SIGN_FILE}"
[[ -n "${ZODIUM_MOK_KEY:-}" ]] || fail "ZODIUM_MOK_KEY env var not set"

WORKDIR="$(mktemp -d)"

PRIVATE_KEY="${WORKDIR}/zodium-mok.pem"
PUBLIC_KEY_CRT="${WORKDIR}/zodium-mok.crt"

printf '%s\n' "${ZODIUM_MOK_KEY}" > "${PRIVATE_KEY}"
chmod 600 "${PRIVATE_KEY}"
[[ -f /zodium-mok.der ]] || fail "/zodium-mok.der not found"
openssl x509 -inform DER -in /zodium-mok.der -out "${PUBLIC_KEY_CRT}"
ok "Signing keys ready"

shopt -s nullglob
SOURCE_RPMS=(/var/cache/akmods/xone/kmod-xone-*.rpm)
shopt -u nullglob
[[ ${#SOURCE_RPMS[@]} -gt 0 ]] || fail "No xone RPM found in /var/cache/akmods/xone/"

# write signing plugin script
SIGN_PLUGIN="${WORKDIR}/sign-modules.sh"
cat > "${SIGN_PLUGIN}" << PLUGIN_EOF
#!/usr/bin/env bash
set -euo pipefail
find "\${RPMREBUILD_BUILDROOT}" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) | while read -r module; do
    final="\${module}"
    if [[ "\${module}" == *.xz ]]; then
        xz -d --rm "\${module}"
        module="\${module%.xz}"
        "${SIGN_FILE}" sha256 "${PRIVATE_KEY}" "${PUBLIC_KEY_CRT}" "\${module}"
        xz -C crc32 -f "\${module}"
        final="\${module}.xz"
    elif [[ "\${module}" == *.zst ]]; then
        zstd -d --rm "\${module}"
        module="\${module%.zst}"
        "${SIGN_FILE}" sha256 "${PRIVATE_KEY}" "${PUBLIC_KEY_CRT}" "\${module}"
        zstd -f --rm "\${module}"
        final="\${module}.zst"
    else
        "${SIGN_FILE}" sha256 "${PRIVATE_KEY}" "${PUBLIC_KEY_CRT}" "\${module}"
    fi
    echo "Signed: \$(basename "\${final}")"
done
PLUGIN_EOF
chmod +x "${SIGN_PLUGIN}"

info "Repacking xone RPM(s) with signed modules..."
for source_rpm in "${SOURCE_RPMS[@]}"; do
    REBUILD_DIR="${WORKDIR}/rebuilt-$(basename "${source_rpm}" .rpm)"
    mkdir -p "${REBUILD_DIR}"

    rpmrebuild -p -n \
        --change-files="${SIGN_PLUGIN}" \
        -d "${REBUILD_DIR}" \
        "${source_rpm}"

    mapfile -t REBUILT_RPMS < <(find "${REBUILD_DIR}" -type f -name '*.rpm')
    [[ ${#REBUILT_RPMS[@]} -gt 0 ]] || fail "rpmrebuild failed for $(basename "${source_rpm}")"

    mv -f "${REBUILT_RPMS[0]}" "${source_rpm}"
    ok "Repacked: $(basename "${source_rpm}")"
done
ok "xone RPM(s) repacked with signed modules"

# ── Locate built RPM ──────────────────────────────────────────
info "Locating built xone kmod RPM..."
shopt -s nullglob
RPMS=(/var/cache/akmods/xone/kmod-xone-*.rpm)
shopt -u nullglob

[[ ${#RPMS[@]} -gt 0 ]] || \
    (cat /var/cache/akmods/xone/*.failed.log 2>/dev/null; \
     fail "No xone kmod RPM found in /var/cache/akmods/xone/")

ok "Built RPMs:"
for rpm in "${RPMS[@]}"; do
    say "  ${CYAN}◈${NC}  $(basename "$rpm")"
done

# ── Download companion packages ───────────────────────────────
info "Downloading xone companion packages..."
dnf download -y --destdir /output/ \
    xone-kmod-common
ok "Companion packages downloaded"

# ── Copy to output ────────────────────────────────────────────
info "Copying RPMs to /output/..."
cp "${RPMS[@]}" /output/
ok "RPMs copied to /output/"

say ""
say "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
say "${MAGENTA}${BOLD}║   ◆  xone kmod build complete                    ║${NC}"
say "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
say ""