# OpenRV 4.0.0 (ASWF) built against Qt 6.11.2 for native Wayland, self-contained under /opt/openrv.
# Built by packaging/build_rpm.sh, which prepares the payload tree (%{stage_root}); this spec only packs it.

%global debug_package %{nil}
%global _build_id_links none
%global __strip /bin/true
%global __os_install_post %{nil}
%global _missing_build_ids_terminate_build 0
%global _binary_payload w19T0.zstdio
%global _source_payload w10.zstdio

# Not Provides: the bundled libQt6*.so.6, libav*, libicu*, ... must NOT satisfy other packages' dependencies.
AutoProv:       no
# Requires are auto-generated (glibc/libstdc++ symbol versions, system GL/Wayland/X11/dbus/... sonames) but
# everything the package carries itself, and interpreter paths of bundled scripts, are filtered out.
%global __requires_exclude %(cat %{requires_filter})

Name:           openrv
Version:        %{rv_version}
Release:        %{rv_release}%{?dist}
Summary:        OpenRV media player and review tool (self-contained Qt 6 / Wayland build)
License:        Apache-2.0 AND LGPL-3.0-only AND LGPL-2.1-or-later AND BSD-3-Clause AND MIT AND Python-2.0.1 AND Zlib AND BSL-1.0 AND MPL-2.0
URL:            https://github.com/AcademySoftwareFoundation/OpenRV
ExclusiveArch:  x86_64
# Fedora's kernel-tools subpackage 'rv' (runtime-verification tool) owns /usr/bin/rv too; /usr/bin/openrv never conflicts
Conflicts:      rv
# Needed at run time, not detectable from the ELF files (data / helper packages of the host)
Requires:       fontconfig
Requires:       xkeyboard-config
Requires:       shared-mime-info
Recommends:     adwaita-sans-fonts
Recommends:     xdg-desktop-portal
Recommends:     mesa-dri-drivers

%description
OpenRV is the open source release of Autodesk's RV: a media player and review tool for image sequences
and movies (EXR, DPX, TIFF, JPEG, H.264/HEVC/ProRes QuickTime, ...), with OpenColorIO, annotations,
Python (PySide6) and Mu scripting.

This build links Qt 6.11.2 and bundles it: Qt, QtWebEngine, ICU, NSS, FFmpeg, Python 3.13, PySide6 and
the other libraries live in /opt/openrv and are found through $ORIGIN-relative RUNPATH and qt.conf, so a
later Fedora release that changes its own Qt does not affect it. Only the C library, the C++ runtime, the
GPU/Wayland/X11/D-Bus/audio/font stack of the host are used from the system.
See /usr/share/doc/openrv/README.packaging.md.

%prep
%build

%install
cp -al %{stage_root}/. %{buildroot}/ 2>/dev/null || cp -a %{stage_root}/. %{buildroot}/

%post
/usr/bin/update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || :
/usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || :
/usr/bin/touch --no-create /usr/share/icons/hicolor >/dev/null 2>&1 || :
exit 0

%postun
if [ $1 -eq 0 ]; then
    /usr/bin/update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || :
    /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || :
fi
exit 0

%files
%defattr(-,root,root,-)
%license /usr/share/licenses/openrv
%doc /usr/share/doc/openrv
/opt/openrv
/usr/bin/rv
/usr/bin/openrv
/usr/bin/rvio
/usr/bin/rvpush
/usr/bin/rvls
/usr/bin/rvpkg
/usr/share/applications/com.aswf.rv.desktop
/usr/share/icons/hicolor/*/apps/openrv.png

%changelog
* Thu Oct 29 2026 Claude <noreply@anthropic.com> - 4.0.0-0.wayland.qt6.1
- First self-contained package: OpenRV main (cade394 + wayland-qt6 patches) with bundled Qt 6.11.2
