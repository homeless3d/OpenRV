# Template: source this file before cmake/ninja. OQ = the workspace directory that holds src/ (a checkout of this
# repository's wayland-qt6 branch), build/, venv/, tools/, sysroot/, dl/ and sysqt6/ (see BUILD_NOTES.md).
# OQ may be exported before sourcing; the default is the workspace two levels above this file (OQ/src/wayland-fedora/env.sh).
export OQ=${OQ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source $OQ/venv/bin/activate
export PATH=$OQ/tools/bin:$PATH
export QT_PREFIX=$OQ/sysqt6/prefix
export CPATH=$OQ/sysroot/usr/include
export LIBRARY_PATH=$OQ/sysroot/usr/lib64
export PERL5LIB=$OQ/dl/perl/usr/share/perl5:$OQ/dl/perl/usr/share/perl5/vendor_perl
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export LLVM_INSTALL_DIR=$OQ/sysqt6/root/usr/lib64/llvm22
export CLANG_INSTALL_DIR=$OQ/sysqt6/root/usr/lib64/llvm22
export CMAKE_INCLUDE_PATH=$OQ/sysroot/usr/include
export CMAKE_LIBRARY_PATH=$OQ/sysroot/usr/lib64
# GCC 16 workarounds: yaml-cpp needs <cstdint>; libdeflate/highway reference removed 'evex512' target attr
export CFLAGS="-D__EVEX512__"
export CXXFLAGS="-include cstdint -D__EVEX512__"
export RV_PYSIDE_SYSTEM_LLVM_DIR=$LLVM_INSTALL_DIR
