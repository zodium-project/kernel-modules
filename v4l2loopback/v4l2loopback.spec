# ================================================================
#  v4l2loopback — RPM spec
#  kmods-zodium : github.com/zodium-project/kmods-zodium
# ================================================================

# ── Disable debug package ─────────────────────────────────────
%global debug_package %{nil}

%define kmod_name       v4l2loopback
%define kernel_mod_dir  /usr/lib/modules/%{kernel_version}/extra/%{kmod_name}

# ================================================================
#  kmod package — kernel module only
#  name includes kernel version per kmod naming convention
# ================================================================
Name:           kmod-%{kmod_name}-%{kernel_version}
Version:        %{kmod_version}
Release:        1%{?dist}
Summary:        V4L2 loopback video device kernel module for %{kernel_version}
License:        GPL-2.0-only
URL:            https://github.com/v4l2loopback/v4l2loopback
Source0:        %{kmod_name}-%{kmod_version}.tar.gz

BuildRequires:  kernel-devel
BuildRequires:  gcc
BuildRequires:  make

# ── Explicit kernel version dependency ────────────────────────
Requires:       kernel

%description
v4l2loopback kernel module built for kernel %{kernel_version}.
Allows creation of virtual V4L2 loopback video devices.
Built by kmods-zodium for the Zodium Project / zcore Linux.

# ================================================================
#  common-utils subpackage — userspace tools
#  no kernel version in name, stable across kernel updates
# ================================================================
%package -n %{kmod_name}-kmod-common-utils
Summary:        Userspace utilities for v4l2loopback
License:        GPL-2.0-only
BuildRequires:  help2man
BuildRequires:  perl
Recommends:     kmod-%{kmod_name}-%{kernel_version} = %{kmod_version}

%description -n %{kmod_name}-kmod-common-utils
Userspace utilities for v4l2loopback including v4l2loopback-ctl
for managing virtual V4L2 loopback devices.

# ================================================================
#  common-devel subpackage — headers
#  noarch, stable across kernel updates
# ================================================================
%package -n %{kmod_name}-kmod-common-devel
Summary:        Development headers for v4l2loopback
License:        GPL-2.0-only
BuildArch:      noarch
Recommends:     kmod-%{kmod_name}-%{kernel_version} = %{kmod_version}

%description -n %{kmod_name}-kmod-common-devel
Development headers for building software against v4l2loopback.

# ================================================================
#  Prep
# ================================================================
%prep
%setup -q -n %{kmod_name}-%{kmod_version}

# ================================================================
#  Build
# ================================================================
%build
# ── kernel module ─────────────────────────────────────────────
make KERNELRELEASE=%{kernel_version} -j%(nproc)

# ── userspace utils ───────────────────────────────────────────
make KERNELRELEASE=%{kernel_version} utils -j%(nproc)

# ================================================================
#  Install
# ================================================================
%install

# ── kmod ──────────────────────────────────────────────────────
install -d %{buildroot}%{kernel_mod_dir}
install -m 0644 %{kmod_name}.ko %{buildroot}%{kernel_mod_dir}/

# ── Sign kmod modules for Secure Boot ────────────────────────
SIGN_FILE="/usr/src/kernels/%{kernel_version}/scripts/sign-file"
[ -x "${SIGN_FILE}" ] || { echo "ERROR: sign-file not found at ${SIGN_FILE}"; exit 1; }
[ -f "%{sign_private_key}" ] || { echo "ERROR: private key not found"; exit 1; }
[ -f "%{sign_public_key}" ] || { echo "ERROR: public key not found"; exit 1; }
for ko in %{buildroot}%{kernel_mod_dir}/*.ko; do
    "${SIGN_FILE}" sha256 "%{sign_private_key}" "%{sign_public_key}" "${ko}" \
        || { echo "ERROR: signing failed for ${ko}"; exit 1; }
done

# ── utils ─────────────────────────────────────────────────────
make KERNELRELEASE=%{kernel_version} install-utils \
    DESTDIR=%{buildroot} \
    PREFIX=%{_prefix}

# ── man pages ─────────────────────────────────────────────────
make KERNELRELEASE=%{kernel_version} install-man \
    DESTDIR=%{buildroot} \
    PREFIX=%{_prefix}

# ── headers ───────────────────────────────────────────────────
make KERNELRELEASE=%{kernel_version} install-headers \
    DESTDIR=%{buildroot} \
    PREFIX=%{_prefix}

# ================================================================
#  Scripts
# ================================================================

# ── depmod on kmod install ────────────────────────────────────
%post
depmod -a %{kernel_version} || :

# ── depmod on kmod uninstall ──────────────────────────────────
%postun
depmod -a %{kernel_version} || :

# ================================================================
#  Files
# ================================================================

# ── kmod ──────────────────────────────────────────────────────
%files
%doc README.md COPYING
%{kernel_mod_dir}/%{kmod_name}.ko

# ── utils ─────────────────────────────────────────────────────
%files -n %{kmod_name}-kmod-common-utils
%{_bindir}/v4l2loopback-ctl
%{_mandir}/man1/v4l2loopback-ctl.1*

# ── devel ─────────────────────────────────────────────────────
%files -n %{kmod_name}-kmod-common-devel
%{_includedir}/linux/v4l2loopback.h

# ================================================================
#  Changelog
# ================================================================
%changelog
* %(date "+%a %b %d %Y") kmods-zodium <zodium-project> - %{kmod_version}-1
- Automated nightly build by kmods-zodium
- Kernel: %{kernel_version}