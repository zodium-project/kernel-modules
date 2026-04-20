# ================================================================
#  openrazer — RPM spec
# ================================================================

# ── Disable debug package ─────────────────────────────────────
%global debug_package %{nil}
%global __strip /bin/true

%define kmod_name       openrazer
%define kernel_mod_dir  /usr/lib/modules/%{kernel_version}/extra/%{kmod_name}

# ================================================================
#  kmod package — kernel modules only
# ================================================================
Name:           kmod-%{kmod_name}-%{kernel_version}
Version:        %{kmod_version}
Release:        1%{?dist}
Summary:        OpenRazer Razer hardware kernel modules for %{kernel_version}
License:        GPL-2.0
URL:            https://github.com/openrazer/openrazer
Source0:        %{kmod_name}-%{kmod_version}.tar.gz

BuildRequires:  kernel-devel
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  openssl-devel

Requires:       kernel
Requires:       %{kmod_name}-kmod-common = %{kmod_version}

%description
OpenRazer kernel modules built for kernel %{kernel_version}.
Provides HID drivers for Razer peripherals (keyboard, mouse, kraken headset,
and accessories) via razerkbd, razermouse, razerkraken, razeraccessory.

# ================================================================
#  common subpackage — daemon, udev rules, plugdev group
# ================================================================
%package -n %{kmod_name}-kmod-common
Summary:        OpenRazer daemon, udev rules and Python library
License:        GPL-2.0
# ── runtime deps (daemon — from daemon/setup.py install_requires) ─
Requires:       python3
Requires:       python3-daemonize
Requires:       python3-dbus
Requires:       python3-gobject
Requires:       python3-pyudev
Requires:       python3-setproctitle
Requires:       xautomation
# ── runtime deps (pylib — from pylib/setup.py install_requires) ──
Requires:       python3-numpy
# ── build deps (needed for setup.py install at rpmbuild time) ────
BuildRequires:  python3
BuildRequires:  python3-devel
BuildRequires:  python3-rpm-macros
BuildRequires:  systemd-rpm-macros
BuildRequires:  python3-setuptools
BuildRequires:  python3-dbus
BuildRequires:  python3-gobject
BuildRequires:  python3-pyudev

%description -n %{kmod_name}-kmod-common
OpenRazer userspace components: daemon (openrazerd), udev rules for Razer
hardware access, plugdev group setup, and the Python library for controlling
Razer peripherals.

# ================================================================
#  Prep
# ================================================================
%prep
%setup -q -n %{kmod_name}-%{kmod_version}

# ================================================================
#  Build
# ================================================================
%build
# ── kernel modules ────────────────────────────────────────────
# builds: razerkbd.ko razermouse.ko razerkraken.ko razeraccessory.ko
make -j%(nproc) driver KERNELDIR=/usr/src/kernels/%{kernel_version}

# ── sign modules (keys pre-staged by build.sh into /tmp/zodium-sign/) ──
SIGN_FILE=/usr/src/kernels/%{kernel_version}/scripts/sign-file
for module in driver/*.ko; do
    ${SIGN_FILE} sha256 \
        /tmp/zodium-sign/private_key.priv \
        /tmp/zodium-sign/public_key.der \
        "${module}"
done

# ================================================================
#  Install
# ================================================================
%install

# ── kmod — copy all 4 .ko files to extra/openrazer/ ──────────
install -d %{buildroot}%{kernel_mod_dir}
cp -p driver/*.ko %{buildroot}%{kernel_mod_dir}/
chmod 0644 %{buildroot}%{kernel_mod_dir}/*.ko

# ── udev rules + razer_mount helper script ────────────────────
# root Makefile correctly forwards DESTDIR/PREFIX for udev_install
# installs:
#   %{_prefix}/lib/udev/rules.d/99-razer.rules
#   %{_prefix}/lib/udev/razer_mount
make udev_install DESTDIR=%{buildroot} PREFIX=%{_prefix} UDEV_PREFIX=%{_prefix}

# ── daemon ────────────────────────────────────────────────────
# call daemon/Makefile directly — root Makefile does not forward DESTDIR
# to its sub-make, so calling via root would install to / not %{buildroot}
# installs:
#   %{_bindir}/openrazer-daemon
#   %{_datadir}/openrazer/razer.conf.example
#   %{_datadir}/dbus-1/services/org.razer.service
#   %{_userunitdir}/openrazer-daemon.service
#   %{_mandir}/man5/razer.conf.5.gz
#   %{_mandir}/man8/openrazer-daemon.8.gz
#   + openrazer_daemon Python package via setup.py into site-packages
make -C daemon install DESTDIR=%{buildroot} PREFIX=%{_prefix}

# ── Python library ────────────────────────────────────────────
# call pylib/Makefile directly for same reason
# installs openrazer Python package via setup.py into site-packages
make -C pylib install DESTDIR=%{buildroot} PREFIX=%{_prefix}

# ================================================================
#  Scripts
# ================================================================

# ── Ensure plugdev group exists before udev rules land ────────
%pre -n %{kmod_name}-kmod-common
getent group plugdev > /dev/null || groupadd -r plugdev
:

# ── Reload udev rules after install ───────────────────────────
%post -n %{kmod_name}-kmod-common
udevadm control --reload-rules 2>/dev/null || :
udevadm trigger            2>/dev/null || :

# ── depmod on kmod install ────────────────────────────────────
%post
depmod -a %{kernel_version} || :

# ── depmod on kmod uninstall ──────────────────────────────────
%postun
depmod -a %{kernel_version} || :

# ================================================================
#  Files
# ================================================================

# ── kmod — 4 razer kernel modules ────────────────────────────
%files
%doc README.md
%{kernel_mod_dir}/razerkbd.ko
%{kernel_mod_dir}/razermouse.ko
%{kernel_mod_dir}/razerkraken.ko
%{kernel_mod_dir}/razeraccessory.ko

# ── common — daemon + udev + pylib ───────────────────────────
%files -n %{kmod_name}-kmod-common
# daemon binary
%{_bindir}/openrazer-daemon
# daemon data files (razer.conf.example)
%{_datadir}/openrazer/
# D-Bus session service activation file
%{_datadir}/dbus-1/services/org.razer.service
# systemd USER service (not system-wide)
%{_userunitdir}/openrazer-daemon.service
# man pages (installed gzipped by daemon Makefile)
%{_mandir}/man5/razer.conf.5*
%{_mandir}/man8/openrazer-daemon.8*
# udev rules + mount helper script
%{_udevrulesdir}/99-razer.rules
%{_udevrulesdir}/../razer_mount
# Python packages installed by setup.py:
#   daemon/setup.py  → name="openrazer_daemon"  → openrazer_daemon/
#   pylib/setup.py   → name="openrazer"          → openrazer/
%{python3_sitelib}/openrazer/
%{python3_sitelib}/openrazer_daemon/
%{python3_sitelib}/openrazer-*.egg-info/
%{python3_sitelib}/openrazer_daemon-*.egg-info/

# ================================================================
#  Changelog
# ================================================================
%changelog
* %(date "+%a %b %d %Y") kmods-zodium <zodium-project> - %{kmod_version}-1
- Automated nightly build by kmods-zodium
- Kernel: %{kernel_version}