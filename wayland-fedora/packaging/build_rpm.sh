#!/bin/bash
# build_rpm.sh -- build the self-contained OpenRV (Qt 6 / Wayland) rpm as a normal user.
#   ./packaging/build_rpm.sh            (no sudo, nothing is installed, nothing is downloaded)
# Output: packaging/out/openrv-<ver>-<rel>.x86_64.rpm   (+ packaging/work/ with the intermediate tree)
#
# Needs: rpmbuild, patchelf, magick (ImageMagick), python3, rsync, zstd and the host's Qt 6 / Chromium
# libraries (the Fedora Qt that the OpenRV build in build/stage was linked against).
set -euo pipefail

PK=$(cd "$(dirname "$0")" && pwd)
OQ=${OQ:-$(dirname "$PK")}               # workspace that contains build/stage (see ../BUILD_NOTES.md)
STAGE=${STAGE:-$OQ/build/stage/app}          # the staged application tree (cmake --install result)
SRC=${SRC:-$(cd "$PK/../.." && pwd)}   # OpenRV source tree = root of this repository
WORK=$PK/work
ROOT=$WORK/root                              # becomes the rpm payload
APP=$ROOT/opt/openrv
QTPLUG=/usr/lib64/qt6/plugins                # host Qt plugins to copy
QTSHARE=/usr/share/qt6
VERSION=${VERSION:-4.0.0}
RELEASE=${RELEASE:-0.wayland.qt6.1}
PATCHELF=${PATCHELF:-$(command -v patchelf)}
export PATH=$HOME/.local/bin:$PATH

for t in rpmbuild "$PATCHELF" magick python3 rsync zstd; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
[ -x "$STAGE/bin/rv.bin" ] || { echo "no staged app at $STAGE" >&2; exit 1; }
QTVER=$(readlink -f /usr/lib64/libQt6Core.so.6 | sed 's/.*\.so\.//')
echo "== OpenRV $VERSION-$RELEASE, host Qt $QTVER, stage $STAGE"

log() { echo; echo "== $*"; }
export REPORT_DIR=$WORK

# ---------------------------------------------------------------- 1. copy the stage
log "1. copy stage -> $APP (without static libs, headers, symbols, build-only files)"
rm -rf "$WORK"; mkdir -p "$APP"
rsync -a \
    --exclude='*.a' --exclude='/include/' --exclude='/src/' --exclude='/symbols/' --exclude='/etc/' \
    --exclude='cmake/' --exclude='pkgconfig/' --exclude='/lib/libMuQt6.a' \
    --exclude='/libexec/' --exclude='/translations/' --exclude='/plugins/Qt/' \
    --exclude='/resources/qtwebengine*' --exclude='/resources/v8_context_snapshot.bin' \
    --exclude='/lib/libvulkan*' \
    --exclude='/lib/python3.13/site-packages/PySide6/Qt/' \
    --exclude='/lib/python3.13/site-packages/PySide6/include/' \
    --exclude='/lib/python3.13/site-packages/PySide6/glue/' \
    --exclude='/lib/python3.13/site-packages/shiboken6_generator/' \
    --exclude='/lib/python3.13/config-3.13-x86_64-linux-gnu/' \
    --exclude='/include/python3.13/' \
    --exclude='/bin/*Test' --exclude='/bin/rvio_sw*' --exclude='/bin/dump_syms' --exclude='/bin/minidump_*' \
    --exclude='/bin/symbolicate_crash.sh' --exclude='/bin/rv.install_handler_linux*' \
    "$STAGE/" "$APP/"
# libraries that are links into the host's Qt (dangling inside the stage) -- recreated below from the host
find "$APP" -xtype l -delete
# the build tree's absolute path must not leak into scripts (python shebang of pip entry points etc.)
grep -rIl --exclude-dir=__pycache__ "$OQ/build/RV_DEPS_PYTHON3/install/bin/python3" "$APP/lib" 2>/dev/null \
    | while read -r f; do sed -i "1s|^#!.*python3[.0-9]*$|#!/opt/openrv/bin/python3|" "$f"; done || true
chmod -R u+rwX,go+rX "$APP"

# ---------------------------------------------------------------- 1b. slimming: nothing for debugging, testing or building
log "1b. slim: remove debug/test/build-only content"
PY=$APP/lib/python3.13; SP=$PY/site-packages
# crash-dump machinery, debug and build helper programs (rv starts without them; see README)
rm -f "$APP"/bin/crashpad_handler* "$APP"/bin/rvprof* "$APP"/bin/makeFBIOformats* "$APP"/bin/makeMovieIOformats* "$APP"/bin/QFontTest
# Python: stdlib test suite, IDLE, tkinter, demos, pip/setuptools/Cython/meson (build tools), test modules, docs
rm -rf "$PY"/test "$PY"/idlelib "$PY"/tkinter "$PY"/turtledemo "$PY"/ensurepip "$PY"/pydoc_data "$PY"/lib2to3 "$PY"/__phello__
rm -f "$PY"/lib-dynload/_test* "$PY"/lib-dynload/xx* "$PY"/lib-dynload/_ctypes_test* "$PY"/lib-dynload/_tkinter*
for d in pip pip-* setuptools setuptools-* pkg_resources _distutils_hack distutils-precedence.pth Cython cython-* cython.py pyximport \
         mesonbuild mesonpy meson_python-* meson-* ninja ninja-* wheel wheel-* pyproject_metadata pyproject_metadata-* tests docs \
         CHANGELOG.rst CONTRIBUTING.rst README.txt; do rm -rf "$SP"/$d; done
find "$APP" -type d \( -name tests -o -name test -o -name testing_data \) -path '*site-packages*' ! -path '*numpy/testing*' -prune -exec rm -rf {} + 2>/dev/null || true
find "$APP" -name '*.pyi' -delete; rm -rf "$SP/PySide6/doc" "$SP/PySide6/typesystems" "$SP/PySide6/scripts"
# PySide6 modules RV (and its Python packages) never import: Designer, Help, Pdf, QuickControls2, QuickTest, SpatialAudio, Sql, WebSockets, WebEngineQuick
for m in Designer Help Pdf PdfWidgets QuickControls2 QuickTest SpatialAudio Sql WebSockets WebEngineQuick; do rm -f "$SP"/PySide6/Qt$m.abi3.so; done
# WebEngine: devtools resources (remote debugging UI) and all locales except en-US and es
rm -f "$APP"/resources/qtwebengine_devtools_resources.pak
find "$APP"/resources/locales -maxdepth 0 -type d -exec rmdir {} + 2>/dev/null || true
find "$APP" -name '__pycache__' -type d -empty -delete 2>/dev/null || true

# ---------------------------------------------------------------- 2. Qt plugin tree, WebEngine, translations from the host
log "2. Qt $QTVER plugin tree, QtWebEngine process/resources, translations (from the host)"
P=$APP/plugins/Qt; mkdir -p "$P"
cp_plugins() {      # cp_plugins <dir> [<glob>...]
    local d=$1; shift
    mkdir -p "$P/$d"
    if [ $# -eq 0 ]; then cp -a "$QTPLUG/$d/." "$P/$d/"; else for g in "$@"; do cp -a "$QTPLUG/$d"/$g "$P/$d/"; done; fi
}
cp_plugins platforms libqwayland.so libqxcb.so libqoffscreen.so libqminimal.so
cp_plugins wayland-decoration-client                       # libadwaita.so (QAdwaitaDecorations), libbradient.so
cp_plugins wayland-graphics-integration-client
cp_plugins wayland-shell-integration
cp_plugins xcbglintegrations
cp_plugins platformthemes libqxdgdesktopportal.so          # libqgtk3.so (needs the whole GTK3 stack) is deliberately left out
cp_plugins platforminputcontexts
cp_plugins iconengines
cp_plugins imageformats libqgif.so libqicns.so libqico.so libqjpeg.so libqsvg.so libqtga.so libqtiff.so libqwbmp.so libqwebp.so
cp_plugins tls
cp_plugins networkinformation libqglib.so libqnetworkmanager.so
# left out on purpose: egldeviceintegrations/eglfs, generic (evdev/libinput/tslib), multimedia (would load host FFmpeg/GStreamer),
# kimg_* (KDE image formats, pull libheif/libraw/libjxl/..), qmltooling, designer, sqldrivers, renderers, sceneparsers, ...
mkdir -p "$APP/libexec" "$APP/resources" "$APP/translations"
cp -a /usr/lib64/qt6/libexec/QtWebEngineProcess "$APP/libexec/"
cp -a "$QTSHARE"/resources/*.pak "$QTSHARE"/resources/v8_context_snapshot.bin "$APP/resources/"
mkdir -p "$APP/translations/qtwebengine_locales"
cp -a "$QTSHARE"/translations/qtwebengine_locales/{en-US,es,es-419}.pak "$APP/translations/qtwebengine_locales/"
cp -a "$QTSHARE"/translations/{qt_es,qtbase_es}.qm "$APP/translations/"
# Qt must find only the bundled copies: qt.conf next to rv.bin and next to QtWebEngineProcess (both relative)
for d in bin libexec; do
cat > "$APP/$d/qt.conf" <<'EOF'
[Paths]
Prefix = ..
Plugins = plugins/Qt
Libraries = lib
LibraryExecutables = libexec
Data = .
Translations = translations
ArchData = .
Imports = qml
QmlImports = qml
EOF
done
# the PySide6 modules look for Qt below PySide6/Qt/: point it at the single bundled copy (no 470 MB duplicate)
PS=$APP/lib/python3.13/site-packages/PySide6
mkdir -p "$PS/Qt"
ln -s ../../../.. "$PS/Qt/lib"; ln -s ../../../../../libexec "$PS/Qt/libexec" 2>/dev/null || true
ln -s ../../../../../resources "$PS/Qt/resources"; ln -s ../../../../../translations "$PS/Qt/translations"

# ---------------------------------------------------------------- 3. RV wrappers
log "3. launchers"
for b in "$APP"/bin/*.bin; do
    n=$(basename "$b" .bin)
    install -m 755 "$PK/launcher/openrv-wrapper.sh" "$APP/bin/$n"
done
# bin/python, python3, python3.13 are real executables in this stage (not wrappers) -> untouched
rm -f "$APP"/bin/crashpad_handler_linux.sh.in
chmod 755 "$APP"/bin/crashpad_handler_linux.sh 2>/dev/null || true

# ---------------------------------------------------------------- 4. shared library closure
log "4. ldd closure (deny list: $PK/excludelist.txt)"
python3 -I "$PK/closure.py" "$APP" "$PK/excludelist.txt" "$PK/dlopen-extras.txt" | tee "$WORK/closure.log"

# ---------------------------------------------------------------- 4b. strip
log "4b. strip --strip-unneeded (keeps .dynsym, so dynamic linking and dlopen are unaffected)"
python3 -I - "$APP" <<'PYEOF'
import os, sys, subprocess
from concurrent.futures import ThreadPoolExecutor
app = sys.argv[1]
fs = []
for d, _, names in os.walk(app):
    for n in names:
        p = os.path.join(d, n)
        if os.path.islink(p): continue
        try:
            with open(p, 'rb') as f: ok = f.read(4) == b'\x7fELF'
        except OSError: ok = False
        if ok: fs.append(p)
before = sum(os.path.getsize(p) for p in fs)
def st(p):
    os.chmod(p, os.stat(p).st_mode | 0o200)
    return subprocess.run(['strip', '--strip-unneeded', p], capture_output=True, text=True).returncode
with ThreadPoolExecutor(12) as ex: rc = list(ex.map(st, fs))
after = sum(os.path.getsize(p) for p in fs)
print('%d ELF files, %d strip failures, %.0f MB -> %.0f MB' % (len(fs), sum(1 for r in rc if r), before/1e6, after/1e6))
PYEOF
ln -sf libpython3.13.so.1.0 "$APP/lib/libpython3.13.so"      # was a hard link; stripping split it into two 32 MB files
chmod -R u+rwX,go+rX "$APP"

# ---------------------------------------------------------------- 5. RUNPATH
log "5. RUNPATH = \$ORIGIN-relative dirs only (patchelf)"
python3 -I - "$APP" "$PATCHELF" <<'PYEOF'
import os, sys, subprocess, collections
from concurrent.futures import ThreadPoolExecutor
app, patchelf = os.path.realpath(sys.argv[1]), sys.argv[2]
env = {k: v for k, v in os.environ.items() if k != 'LD_LIBRARY_PATH'}
env['LD_LIBRARY_PATH'] = app + '/lib:' + app + '/lib/OpenSSL'
def is_elf(p):
    try:
        with open(p, 'rb') as f: return f.read(4) == b'\x7fELF'
    except OSError: return False
files = []
for d, _, fs in os.walk(app):
    for f in fs:
        p = os.path.join(d, f)
        if not os.path.islink(p) and is_elf(p): files.append(p)
def compute(p):
    out = subprocess.run(['ldd', p], capture_output=True, text=True, env=env).stdout
    dirs = collections.OrderedDict()
    here = os.path.dirname(p)
    for l in out.splitlines():
        if '=>' not in l: continue
        path = l.split('=>')[1].split(' (')[0].strip()
        if path.startswith(app + os.sep):
            dirs[os.path.dirname(path)] = 1
    dirs[app + '/lib'] = 1                      # always: the main library dir
    rp = []
    for d in dirs:
        rel = os.path.relpath(d, here)
        rp.append('$ORIGIN' + ('' if rel == '.' else '/' + rel))
    return p, ':'.join(rp)
def apply(a):
    p, rp = a
    r = subprocess.run([patchelf, '--set-rpath', rp, p], capture_output=True, text=True)
    return p, r.returncode, r.stderr.strip()
fail = 0
with ThreadPoolExecutor(8) as ex:
    plan = list(ex.map(compute, files))      # phase 1: resolve everything while the tree is untouched
with ThreadPoolExecutor(8) as ex:
    for p, rc, err in ex.map(apply, plan):   # phase 2: rewrite
        if rc:
            fail += 1; print('patchelf failed (kept as is):', os.path.relpath(p, app), err[:100])
print('RUNPATH set on %d ELF files (%d skipped)' % (len(files) - fail, fail))
PYEOF

# ---------------------------------------------------------------- 6. desktop integration, /usr/bin
log "6. desktop file, icons, /usr/bin links, licenses"
mkdir -p "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/usr/share/licenses/openrv" "$ROOT/usr/share/doc/openrv"
for n in rv rvio rvpush rvls rvpkg; do ln -s /opt/openrv/bin/$n "$ROOT/usr/bin/$n"; done
ln -s /opt/openrv/bin/rv "$ROOT/usr/bin/openrv"     # alias: Fedora's kernel-tools 'rv' package also owns /usr/bin/rv
install -m 644 "$PK/com.aswf.rv.desktop" "$ROOT/usr/share/applications/com.aswf.rv.desktop"
ICO=$SRC/src/bin/apps/rv/RV.ico
H=$ROOT/usr/share/icons/hicolor
for i in 0:16 1:24 2:32 3:48 4:64 6:128 7:256; do
    mkdir -p "$H/${i#*:}x${i#*:}/apps"
    magick "$ICO[${i%%:*}]" -strip "PNG32:$H/${i#*:}x${i#*:}/apps/openrv.png"
done
# 512x512 from the macOS icon (the OpenRV tree's RV.icns holds PNG 'ic09')
python3 -I - "$SRC/src/bin/nsapps/RV/RV.icns" "$H" <<'PYEOF'
import struct, sys, os
d = open(sys.argv[1], 'rb').read(); i = 8
while i < len(d):
    t, l = d[i:i+4], struct.unpack('>I', d[i+4:i+8])[0]
    if t == b'ic09':
        os.makedirs(sys.argv[2] + '/512x512/apps', exist_ok=True)
        open(sys.argv[2] + '/512x512/apps/openrv.png', 'wb').write(d[i+8:i+l])
    i += l
PYEOF
cp "$SRC/LICENSE" "$ROOT/usr/share/licenses/openrv/LICENSE" 2>/dev/null || true
cp "$SRC/Notice.txt" "$SRC/THIRD-PARTY.md" "$ROOT/usr/share/licenses/openrv/"
cp "$PK/BUNDLED-QT-NOTE.txt" "$ROOT/usr/share/licenses/openrv/"
cp "$PK/README.md" "$ROOT/usr/share/doc/openrv/README.packaging.md"

# ---------------------------------------------------------------- 7. verification of the tree, requires filter
log "7. verify: with EMPTY library path every dependency must be inside the tree or deny-listed"
python3 -I "$PK/closure.py" "$APP" "$PK/excludelist.txt" "$PK/dlopen-extras.txt" --verify | tee "$WORK/verify.log"

# rpm must not Require what the package carries itself (and must not Provide it either: AutoProv is off).
python3 -I - "$APP" "$WORK/requires-exclude.regex" <<'PYEOF'
import os, re, sys
app, out = sys.argv[1], sys.argv[2]
names = set()
for d, ds, fs in os.walk(app):
    for f in fs:
        if re.search(r'\.so(\.|$)', f) or f.endswith('.abi3.so'):
            names.add(f)
alt = '|'.join(sorted(re.escape(n).replace('\\+', '[+]') for n in names))
# file requires (interpreters of the bundled scripts: /usr/bin/env, /bin/sh ...) and bundled sonames
open(out, 'w').write('^/|^(' + alt + ')([(]|$)')
print('requires filter: %d bundled sonames' % len(names))
PYEOF

# ---------------------------------------------------------------- 8. rpmbuild
log "8. rpmbuild"
mkdir -p "$WORK/rpmbuild"/{BUILD,RPMS,SRPMS,SOURCES,SPECS} "$PK/out"
rm -f "$PK"/out/*.rpm
rpmbuild -bb "$PK/openrv.spec" \
    --define "_topdir $WORK/rpmbuild" \
    --define "_rpmdir $PK/out" \
    --define "stage_root $ROOT" \
    --define "requires_filter $WORK/requires-exclude.regex" \
    --define "rv_version $VERSION" --define "rv_release $RELEASE" \
    --buildroot "$WORK/rpmbuild/BUILDROOT" 2>&1 | tail -40
mv "$PK"/out/x86_64/*.rpm "$PK/out/" && rmdir "$PK/out/x86_64"
ls -l "$PK"/out/*.rpm
