#!/bin/sh
# OpenRV launcher of the "system" variant (installed as /opt/openrv-system/bin/<name>; /usr/bin/<name> is a symlink to it).
# One script serves rv, rvio, rvpush, rvls, rvpkg, ... : it execs the sibling "<name>.bin".
# It is relocatable: everything is derived from the location of this file.
# Unlike the bundled variant's launcher it does NOT isolate Qt: Qt 6 (libraries, plugins, QtWebEngineProcess, resources)
# is the system's, found through the normal loader search path and Qt's compiled-in paths, so QT_* variables of the user
# (QT_QPA_PLATFORMTHEME, QT_PLUGIN_PATH ...) keep working as for any other Qt application.
self=$(readlink -f "$0")
here=${self%/*}
name=${self##*/}
export RV_HOME=${here%/*}

bin="$RV_HOME/bin/$name.bin"
if [ ! -x "$bin" ]; then
    echo "$name: $bin not found" >&2
    exit 127
fi

# Only Python and the loader are kept private (RUNPATH of every RV library is $ORIGIN-relative; no LD_LIBRARY_PATH).
unset PYTHONHOME BUILD_ROOT LD_PRELOAD
PATH="$RV_HOME/bin:$PATH"; export PATH

# Native Wayland when a Wayland compositor is reachable, X11 (xcb) otherwise.
if [ -z "${QT_QPA_PLATFORM+x}" ]; then
    if [ -n "$WAYLAND_DISPLAY" ] || [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/wayland-0" ]; then
        QT_QPA_PLATFORM="wayland;xcb"
    else
        QT_QPA_PLATFORM="xcb"
    fi
    export QT_QPA_PLATFORM
fi
# GNOME-style client side decoration: plugin from Fedora's qt6-qtwayland-adwaita-decoration
: "${QT_WAYLAND_DECORATION=adwaita}"; export QT_WAYLAND_DECORATION

# Crashpad is not shipped; without this switch rv prints "Crashpad handler not found" errors.
: "${RV_CRASH_DUMPS_ENABLED=0}"; export RV_CRASH_DUMPS_ENABLED

# Upstream's wrapper does this for the GUI ("LANG causes problems when set to interesting values")
[ "$name" = rv ] && unset LANG

exec "$bin" "$@"
