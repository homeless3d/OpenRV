#!/bin/bash
# make_qt_prefix.sh -- build the synthetic Qt prefix that OpenRV is configured with (-DRV_DEPS_QT_LOCATION=$OQ/sysqt6/prefix).
#
# Why: OpenRV's build wants ONE Qt prefix with headers, cmake files, tools and libraries. Fedora splits Qt in
# runtime packages (installed, in /usr) and -devel packages (headers, cmake, mkspecs, tools; NOT installed here, no root).
# This script downloads the -devel rpms (plus the clang/llvm devel rpms PySide6's shiboken needs), unpacks them
# WITHOUT installing (rpm2cpio | cpio), and assembles a prefix that is a symlink farm over
#     <unpacked devel rpms>  +  the installed runtime Qt in /usr
# with the few fixes OpenRV/PySide6 need (see BUILD_NOTES.md "sysqt6/prefix fixes").
# Nothing is installed, no repository is added, no root is needed. Re-running is safe (idempotent, rebuilds the prefix).
#
# usage:  tools/make_qt_prefix.sh [OUT_DIR]          OUT_DIR default: $OQ/sysqt6 (or ./sysqt6)
# env:    RPM_DIR     where the rpms are/will be downloaded (default OUT_DIR/rpms; existing rpms there are reused,
#                     nothing is downloaded if SKIP_DOWNLOAD=1)
#         EXTRA_PKGS  more rpm names to download+unpack (space separated)
#         DNF         dnf binary (default dnf)
# result: OUT_DIR/{rpms,root,prefix}; use  -DRV_DEPS_QT_LOCATION=OUT_DIR/prefix
#         and  RV_PYSIDE_SYSTEM_LLVM_DIR=CLANG_INSTALL_DIR=LLVM_INSTALL_DIR=OUT_DIR/root/usr/lib64/llvmNN  (printed at the end)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "${1:-${OQ:-$PWD}/sysqt6}")
RPM_DIR=${RPM_DIR:-$OUT/rpms}
ROOT=$OUT/root
PREFIX=$OUT/prefix
DNF=${DNF:-dnf}
QTVER=$(rpm -q --qf '%{VERSION}' qt6-qtbase 2>/dev/null || true)
[ -n "$QTVER" ] || { echo "the runtime qt6-qtbase must be installed (the prefix links to /usr)" >&2; exit 1; }

# Runtime packages are expected to be installed already (qt6-qtbase, qt6-qtwayland, qt6-qtwebengine, ...: rpm -q).
# -devel: everything OpenRV (`Qt6` components it find_package()s) + PySide6 touch.  qttools/linguist: real lupdate/lrelease
# ELF files that PySide6 copies; clang-*/llvm-devel: shiboken6 generator uses the system clang instead of downloading libclang.
PKGS="qt6-qtbase-devel qt6-qtbase-private-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel qt6-qt5compat-devel
 qt6-qtpdf-devel qt6-qtpositioning-devel qt6-qtshadertools-devel qt6-qtsvg-devel qt6-qttools-devel qt6-qtwayland-devel
 qt6-qtwebchannel-devel qt6-qtwebengine-devel qt6-qtwebsockets-devel qt6-qttools qt6-linguist
 clang-devel clang-libs llvm-devel ${EXTRA_PKGS:-}"

mkdir -p "$RPM_DIR"

# ---------------------------------------------------------------- 1. download (no root, only the stock repos)
if [ "${SKIP_DOWNLOAD:-0}" != 1 ]; then
  echo "== 1. dnf download (fedora + updates only) -> $RPM_DIR"
  # Pin the -devel packages to the installed runtime Qt version where possible (a mismatch would break the build).
  $DNF download --arch=x86_64 --disablerepo='*' --enablerepo=fedora --enablerepo=updates \
      --destdir="$RPM_DIR" $PKGS
fi
if ls "$RPM_DIR"/qt6-qtbase-devel-*.rpm >/dev/null 2>&1; then
  DEVVER=$(rpm -qp --qf '%{VERSION}' "$RPM_DIR"/qt6-qtbase-devel-*.rpm | head -1)
  [ "$DEVVER" = "$QTVER" ] || echo "WARNING: -devel rpms are Qt $DEVVER but the installed runtime is $QTVER; run dnf update or pick matching rpms" >&2
else
  echo "no qt6-qtbase-devel rpm in $RPM_DIR" >&2; exit 1
fi

# ---------------------------------------------------------------- 2. unpack (not install)
echo "== 2. unpack rpms -> $ROOT"
rm -rf "$ROOT"; mkdir -p "$ROOT"
for r in "$RPM_DIR"/*.rpm; do ( cd "$ROOT" && rpm2cpio "$r" | cpio -idmu --quiet ); done
chmod -R u+rwX "$ROOT"

# ---------------------------------------------------------------- 3. layout (python does the symlink farm)
echo "== 3. assemble prefix -> $PREFIX"
python3 -I "$HERE/qt_prefix_farm.py" "$ROOT" "$PREFIX" "$QTVER"

echo
echo "done. Qt $QTVER prefix: $PREFIX"
LLVMDIR=$(ls -d "$ROOT"/usr/lib64/llvm[0-9]* 2>/dev/null | head -1 || true)
echo "  cmake ... -DRV_DEPS_QT_LOCATION=$PREFIX"
[ -n "$LLVMDIR" ] && echo "  export LLVM_INSTALL_DIR=$LLVMDIR CLANG_INSTALL_DIR=$LLVMDIR RV_PYSIDE_SYSTEM_LLVM_DIR=$LLVMDIR"
exit 0
