#!/bin/sh
# OpenRV launcher (installed as /opt/openrv/bin/<name>; /usr/bin/<name> is a symlink to it).
# One script serves rv, rvio, rvpush, rvls, rvpkg, ... : it execs the sibling "<name>.bin".
# It is relocatable: everything is derived from the location of this file.
self=$(readlink -f "$0")
here=${self%/*}
name=${self##*/}
export RV_HOME=${here%/*}

bin="$RV_HOME/bin/$name.bin"
if [ ! -x "$bin" ]; then
    echo "$name: $bin not found" >&2
    exit 127
fi

# Isolation: Qt, Python and the dynamic loader must only see the bundled copies.
# (RUNPATH of every bundled library is $ORIGIN-relative, so LD_LIBRARY_PATH is not used at all.)
unset QT_PLUGIN_PATH QT_QPA_PLATFORM_PLUGIN_PATH QML2_IMPORT_PATH QML_IMPORT_PATH QT_QPA_PLATFORMTHEME \
      PYTHONHOME BUILD_ROOT LD_PRELOAD
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
# GNOME-style client side decoration (libadwaita look), shipped in plugins/Qt/wayland-decoration-client
: "${QT_WAYLAND_DECORATION=adwaita}"; export QT_WAYLAND_DECORATION

# Upstream's wrapper does this for the GUI ("LANG causes problems when set to interesting values")
[ "$name" = rv ] && unset LANG

exec "$bin" "$@"
