#!/bin/bash
# build_rpm.sh -- build the self-contained OpenRV (Qt 6 / Wayland) rpm as a normal user.
#   ./packaging/build_rpm.sh            (no sudo, nothing is installed, nothing is downloaded)
# Output: packaging/out/openrv-<ver>-<rel>.x86_64.rpm   (+ packaging/work/ with the intermediate tree)
#
# Needs: rpmbuild, patchelf, magick (ImageMagick), python3, rsync, zstd and the host's Qt 6 / Chromium
# libraries (the Fedora Qt that the OpenRV build in build/stage was linked against).
set -euo pipefail

PK=$(cd "$(dirname "$0")" && pwd)
OQ=$(dirname "$PK")
STAGE=${STAGE:-$OQ/build/stage/app}          # the staged application tree (cmake --install result)
SRC=$OQ/src
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
SVG=$SRC/src/bin/apps/rv/RV.svg
H=$ROOT/usr/share/icons/hicolor
for n in 16 24 32 48 64 128 256 512; do
    mkdir -p "$H/${n}x${n}/apps"
    magick -background none -density $((n * 96 / 400 + 1)) "$SVG" -resize ${n}x${n} -strip "PNG32:$H/${n}x${n}/apps/openrv.png"
done
mkdir -p "$H/scalable/apps"; install -m 644 "$SVG" "$H/scalable/apps/openrv.svg"
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

# ---------------------------------------------------------------- 7b. precompiled Mu modules (.muc / .mud)
# rv compiles every Mu module from source at each start and again whenever an optional package mode is switched
# on (session_manager, annotate, doc_browser, ...). With "-debug compile" Mu writes the compiled .muc (and the .mud
# doc) next to the .mu file; /opt/openrv is read-only for users, so they must be shipped. There is NO staleness
# check in Mu: a .muc silently wins over an edited .mu, hence they are generated here from the final tree, never in
# build/stage. A module only gets a .muc when it is actually loaded during that run, so after the normal startup an
# "-eval" expression (it runs last, once the session is up) does runtime.load_module() on EVERY plugins/Mu/*.mu found
# in the tree (list generated here, new packages are covered automatically) and writes one result line per module
# plus a sentinel line to a file in the private HOME (rv's stdout is block-buffered when redirected and the installed
# launcher drops LD_PRELOAD, so stdbuf cannot help); that file is polled (no guessing with file counts). Expected set = every .mu minus MUC_EXCLUDE; the build fails and lists
# the modules whose .muc is missing or whose load did not return true.
# MUC_EXCLUDE (default "external_ioprocess maya_tools rvnuke_mode"), all verified in rv 4.0.0 / this tree:
#   external_ioprocess  compiling it makes rv SEGFAULT in Mu::Archive::Writer::freeze() (upstream Mu bug; nothing loads
#                       it, the ExternalProcess users use external_qprocess); the crash leaves a truncated .muc.
#   maya_tools          compiles, but loading its .muc in a fresh rv SEGFAULTS (the source loads fine).
#   rvnuke_mode         same (its source also has an unresolved call, "menuItem" at line 2014, that Mu only reports).
# Two passes therefore run: pass 1 "-debug compile" writes the .muc; pass 2 is a plain rv (no compile) in a FRESH
# process that loads every .muc, so a .muc that cannot be loaded back fails the build instead of shipping. Verified: rvio (-overlay frameburn/watermark/matte/bug, -leader simpleslate) loads these same .muc
# and renders byte-identical frames, so rv-compiled overlay scripts are safe to ship.
# Display: rv needs a GL-capable display (Qt "offscreen"/"minimal" abort without a GL context; mu-interp cannot be
# used, the "commands" module only exists inside rv). MUC_DISPLAY=auto|xvfb-run|xvfb|weston|session picks it; auto =
#   1. xvfb-run (xorg-x11-server-Xvfb)        2. private Xvfb on a free display number (-displayfd)
#   3. private headless weston (--backend=headless --renderer=gl, own socket in a private XDG_RUNTIME_DIR)
#   4. the current $DISPLAY / $WAYLAND_DISPLAY (a short-lived rv window appears)       5. error with instructions.
# Everything started here is stopped by PID / process group.
log "7b. precompile the Mu modules (rv -debug compile -eval 'load every module', headless)"
MUC_DISPLAY=${MUC_DISPLAY:-auto}
MUC_EXCLUDE=${MUC_EXCLUDE-external_ioprocess maya_tools rvnuke_mode}
MUC_TIMEOUT=${MUC_TIMEOUT:-60}
GENHOME=$(mktemp -d "${TMPDIR:-/tmp}/openrv-muc-home.XXXXXX")
GENPID=; MUC_BG=(); MUC_DIRS=("$GENHOME"); GENX=(); GENENV=()
( cd "$APP" && find . | sort ) > "$WORK/tree-before-muc.txt"

muc_stop_rv() {    # the rv process group, then anything still running from the tree
    local p e
    if [ -n "$GENPID" ]; then
        kill -TERM -- -"$GENPID" 2>/dev/null || true; sleep 1; kill -KILL -- -"$GENPID" 2>/dev/null || true
        wait "$GENPID" 2>/dev/null || true; GENPID=
    fi
    for p in /proc/[0-9]*; do
        e=$(readlink "$p/exe" 2>/dev/null || true)
        case $e in "$APP"/*) kill -KILL "${p#/proc/}" 2>/dev/null || true;; esac
    done
}
muc_stop() {       # idempotent: rv, then the display servers started below, then the private directories
    local p
    muc_stop_rv
    for p in "${MUC_BG[@]}"; do
        pkill -TERM -P "$p" 2>/dev/null || true         # children of weston (desktop-shell, keyboard)
        kill -TERM "$p" 2>/dev/null || true; sleep 0.5; kill -KILL "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    MUC_BG=()
    if [ "${#MUC_DIRS[@]}" -gt 0 ]; then rm -rf "${MUC_DIRS[@]}"; MUC_DIRS=(); fi
}
trap muc_stop EXIT

muc_display_xvfbrun() {
    command -v xvfb-run >/dev/null || return 1
    GENX=(xvfb-run -a -s "-screen 0 1280x720x24 +extension GLX")
    GENENV=(-u WAYLAND_DISPLAY QT_QPA_PLATFORM=xcb)
}
muc_display_xvfb() {
    command -v Xvfb >/dev/null || return 1
    local f=$GENHOME/displayfd i
    : > "$f"
    Xvfb -displayfd 3 -screen 0 1280x720x24 +extension GLX -nolisten tcp 3>"$f" > "$WORK/muc-xvfb.log" 2>&1 &
    MUC_BG+=($!)
    for i in $(seq 100); do [ -s "$f" ] && break; kill -0 "$!" 2>/dev/null || break; sleep 0.1; done
    [ -s "$f" ] || { echo "Xvfb did not report a display number, see $WORK/muc-xvfb.log" >&2; return 1; }
    GENX=(); GENENV=(-u WAYLAND_DISPLAY DISPLAY=":$(head -n1 "$f")" QT_QPA_PLATFORM=xcb)
}
muc_display_weston() {
    command -v weston >/dev/null || return 1
    local d i
    d=$(mktemp -d /tmp/openrv-wl.XXXXXX); chmod 700 "$d"     # short path: a wayland socket path is limited to ~100 chars
    MUC_DIRS+=("$d")
    XDG_RUNTIME_DIR=$d weston --backend=headless --renderer=gl --socket=openrv-muc --no-config \
        --width=1280 --height=720 > "$WORK/muc-weston.log" 2>&1 &
    MUC_BG+=($!)
    for i in $(seq 100); do [ -S "$d/openrv-muc" ] && break; kill -0 "$!" 2>/dev/null || break; sleep 0.1; done
    [ -S "$d/openrv-muc" ] || { echo "weston (headless, gl renderer) did not start, see $WORK/muc-weston.log" >&2; return 1; }
    GENX=(); GENENV=(-u DISPLAY XDG_RUNTIME_DIR="$d" WAYLAND_DISPLAY=openrv-muc QT_QPA_PLATFORM=wayland)
}
muc_display_session() {
    if [ -n "${DISPLAY:-}" ]; then
        echo "warning: using the current X display $DISPLAY, a short-lived rv window will appear"
        GENX=(); GENENV=(-u WAYLAND_DISPLAY QT_QPA_PLATFORM=xcb)
    elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "warning: using the current Wayland display $WAYLAND_DISPLAY, a short-lived rv window will appear"
        GENX=(); GENENV=(QT_QPA_PLATFORM=wayland)
    else return 1; fi
}
muc_pick_display() {
    local m
    case $MUC_DISPLAY in
        auto) for m in xvfbrun xvfb weston session; do
                  if "muc_display_$m"; then echo "Mu precompile display: ${m/xvfbrun/xvfb-run}"; return 0; fi
              done ;;
        xvfb-run) muc_display_xvfbrun && { echo "Mu precompile display: xvfb-run"; return 0; } ;;
        xvfb|weston|session) "muc_display_$MUC_DISPLAY" && { echo "Mu precompile display: $MUC_DISPLAY"; return 0; } ;;
        *) echo "ERROR: MUC_DISPLAY must be auto|xvfb-run|xvfb|weston|session (got '$MUC_DISPLAY')" >&2; exit 1 ;;
    esac
    cat >&2 <<'MSG'
ERROR: no display available to precompile the Mu modules (rv needs a GL-capable display; QT_QPA_PLATFORM=offscreen
       and minimal abort without a GL context). Install one of these (no desktop session needed), then re-run:
         sudo dnf install xorg-x11-server-Xvfb      # provides xvfb-run and Xvfb (preferred)
         sudo dnf install weston                    # private headless Wayland compositor (GL renderer)
       or run from inside a graphical session (a short-lived rv window appears): MUC_DISPLAY=session
MSG
    exit 1
}
muc_pick_display

# eval: load every module, one result line each into $MUC_RES, sentinel last, then close (= flush) the file
MUC_RES=$GENHOME/muc-result.txt
MUC_ALL=$(cd "$APP/plugins/Mu" && ls -- *.mu | sed 's/\.mu$//' | LC_ALL=C sort)
MUC_EXPECT=$(printf '%s\n' $MUC_ALL | grep -vxF -f <(printf '%s\n' $MUC_EXCLUDE | grep . || echo '#none#') || true)
muc_run() {        # muc_run LOGNAME [extra rv args]: fresh rv, eval loads all, polls the result file for the sentinel
    local name=$1; shift
    rm -f "$MUC_RES"
    setsid env "${GENENV[@]}" HOME="$GENHOME" RV_HOME="$APP" \
        "${GENX[@]}" "$APP/bin/rv" -noPrefs "$@" -eval "$MUC_EV" > "$WORK/$name.log" 2>&1 &
    GENPID=$!
    for _ in $(seq "$MUC_TIMEOUT"); do
        sleep 1
        grep -qs '^OPENRV-MUC-DONE' "$MUC_RES" && break
        kill -0 "$GENPID" 2>/dev/null || break
    done
    cp "$MUC_RES" "$WORK/$name.result" 2>/dev/null || : > "$WORK/$name.result"
    muc_stop_rv
}
MUC_EV="use runtime; use io; ofstream o = ofstream(\"$MUC_RES\");"
for m in $MUC_EXPECT; do
    MUC_EV+=" try { print(o, \"MUC-LOAD $m \" + string(runtime.load_module(\"$m\")) + \"\\n\"); flush(o); } catch (...) { print(o, \"MUC-LOAD $m EXC\\n\"); flush(o); }"
done
MUC_EV+=' print(o, "OPENRV-MUC-DONE\n"); o.close();'
muc_run muc-gen -debug compile                 # pass 1: compile
cp "$WORK/muc-gen.result" "$WORK/muc-result.txt"
muc_run muc-check                              # pass 2: load every .muc back, no compile
muc_stop
trap - EXIT
rmdir "$APP/resources/locales" 2>/dev/null || true       # re-created (empty) by QtWebEngine

n=$(find "$APP/plugins/Mu" -maxdepth 1 -name '*.muc' | wc -l)
nexp=$(printf '%s\n' $MUC_EXPECT | grep -c .)
echo "$n .muc and $(find "$APP/plugins/Mu" -maxdepth 1 -name '*.mud' | wc -l) .mud files in plugins/Mu (expected $nexp .muc = $(printf '%s\n' $MUC_ALL | grep -c .) .mu minus excluded: ${MUC_EXCLUDE:-none})"
bad=
for pass in muc-gen muc-check; do
    grep -q '^OPENRV-MUC-DONE' "$WORK/$pass.result" || bad+=" ($pass: rv did not reach the sentinel within ${MUC_TIMEOUT}s or crashed)"
    first=1
    for m in $MUC_EXPECT; do      # modules load in this order: the first one without a result line is where rv died
        if grep -q "^MUC-LOAD $m true\$" "$WORK/$pass.result"; then continue
        elif grep -q "^MUC-LOAD $m " "$WORK/$pass.result"; then bad+=" $m($pass: load returned false/exception)"
        elif [ "$first" = 1 ]; then bad+=" $m($pass: rv died or hung at/after this module -- add it to MUC_EXCLUDE?)"; first=0
        fi
    done
done
for m in $MUC_EXPECT; do [ -s "$APP/plugins/Mu/$m.muc" ] || bad+=" $m(no .muc)"; done
for m in $MUC_EXCLUDE; do rm -f "$APP/plugins/Mu/$m.muc" "$APP/plugins/Mu/$m.mud"; done
grep -E 'Unable to open output|failed to load muc|archive format|INFO: compiled' "$WORK/muc-check.log" && bad+=" (muc-check pass compiled or failed to read a .muc)"
grep -E 'Unable to open output|failed to load muc|archive format' "$WORK/muc-gen.log" && bad+=" (muc write/read errors in log)"
if [ -n "$bad" ]; then echo "ERROR: Mu precompile incomplete:$bad -- see $WORK/muc-gen.log, $WORK/muc-check.log" >&2; exit 1; fi
grep -E '^(ERROR|.*Unresolved function)' "$WORK/muc-gen.log" | grep -v 'NV-GLX' | sed 's/^/note (source problem in the module itself, not caused by precompiling): /' || true
( cd "$APP" && find . | sort ) > "$WORK/tree-after-muc.txt"
extra=$(diff "$WORK/tree-before-muc.txt" "$WORK/tree-after-muc.txt" | grep '^>' | grep -v -E '^> \./plugins/Mu/[^/]+\.mu[cd]$' || true)
if [ -n "$extra" ]; then echo "ERROR: the Mu precompile step wrote other files into the tree:" >&2; echo "$extra" >&2; exit 1; fi
chmod -R u+rwX,go+rX "$APP"

# ---------------------------------------------------------------- 7c. Python bytecode that stays valid after packaging
# The stage's .pyc files are timestamp-based (they record the .py mtime), but rpmbuild clamps every file mtime, so in
# the installed tree EVERY .pyc was stale; /opt is root-owned so rv could not rewrite them and recompiled every
# module it imported (stdlib, PySide6, plugins) at each start. Hash-based .pyc (checked: validated against the
# source's content hash, independent of mtime) survive the clamp.
log "7c. hash-based bytecode for the bundled Python tree"
find "$APP" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
"$APP/bin/python3" -I -m compileall -q -f -j 0 --invalidation-mode checked-hash "$APP/lib" "$APP/plugins" >"$WORK/pyc.log" 2>&1 || true
echo "    $(find "$APP" -name '*.pyc' | wc -l) .pyc written (compile errors, if any, in $WORK/pyc.log)"

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
