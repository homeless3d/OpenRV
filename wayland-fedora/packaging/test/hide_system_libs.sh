#!/bin/bash
# hide_system_libs.sh <cmd...>
# Runs <cmd> in an unprivileged user+mount namespace in which /usr/lib64 is replaced by a symlink farm that
# omits every host Qt6 / FFmpeg / ICU / NSS / xkbcommon / xcb-util / webp / ... library (everything that the package
# bundles), so the program can only work if it really uses its own copies. /usr/lib64/qt6 is hidden as well.
# GPU drivers, glibc, Wayland etc. -- and the private dependencies of the system libraries (bz2, brotli, ssl, zstd ...) --
# stay visible (symlinks to the real directory).
HIDE='^(libQt6|libicu|libav|libsw|libpostproc|libnss|libnspr|libsmime|libplc|libplds|libxkbcommon|libxcb-(cursor|icccm|image|keysyms|render-util|render|shape|util|xkb|xinerama|xinput)|libwebp|libsharpyuv|libdouble-conversion|libb2|libpcre2-16|libmd4c|libminizip|libxml2|libxslt|libre2|libjsoncpp|libsnappy|libabsl|libopus|libopenjp2|libLerc|libxkbfile|liblcms)'
# (outer namespace: root, to be allowed to mount; the program itself runs in a nested namespace as the real uid,
#  because Chromium refuses to run as root)
export HOST_UID=$(id -u) HOST_GID=$(id -g)
exec unshare -r -m bash -c '
set -e
mkdir -p /tmp/.real64 /tmp/.farm
mount --bind /usr/lib64 /tmp/.real64
mount -t tmpfs tmpfs /tmp/.farm
for f in /tmp/.real64/* /tmp/.real64/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = qt6 ] && continue
    echo "$b" | grep -Eq "'"$HIDE"'" && continue
    ln -s "/tmp/.real64/$b" "/tmp/.farm/$b"
done
mount --bind /tmp/.farm /usr/lib64
echo "visible Qt/ICU/ffmpeg libs in /usr/lib64 inside the namespace: $(ls /usr/lib64 | grep -Ec "libQt6|libicu|libav(codec|format|util)")"
exec unshare -U --map-user=$HOST_UID --map-group=$HOST_GID "$@"
' hide "$@"
