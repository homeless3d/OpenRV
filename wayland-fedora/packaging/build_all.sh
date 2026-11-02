#!/bin/bash
# build_all.sh -- build BOTH OpenRV rpms into packaging/out/ (one command, every iteration):
#   openrv-<ver>-<rel>.rpm          VARIANT=bundled  (self-contained, /opt/openrv)
#   openrv-system-<ver>-<rel>.rpm   VARIANT=system   (system Qt/Chromium via dnf, /opt/openrv-system)
# Same VERSION / RELEASE / STAGE / PATCHELF / MUC_* environment for both. Fails if either build fails.
set -uo pipefail
PK=$(cd "$(dirname "$0")" && pwd)
export VERSION=${VERSION:-4.0.0} RELEASE=${RELEASE:-0.wayland.qt6.1}
rc=0
for v in bundled system; do
    echo; echo "################ VARIANT=$v ################"
    if ! VARIANT=$v "$PK/build_rpm.sh"; then echo "ERROR: VARIANT=$v build FAILED" >&2; rc=1; fi
done
echo; echo "################ result ################"
for n in openrv openrv-system; do
    f=$(ls "$PK/out/$n-$VERSION-"*.rpm 2>/dev/null | head -1)
    if [ -n "$f" ]; then printf '%-14s %s  %s\n' "$n" "$f" "$(du -h "$f" | cut -f1) ($(stat -c %s "$f") bytes)"
    else printf '%-14s MISSING\n' "$n"; rc=1; fi
done
exit $rc
