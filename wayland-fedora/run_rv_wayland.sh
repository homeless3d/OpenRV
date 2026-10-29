#!/bin/bash
# Launch the system-Qt6 OpenRV build natively on Wayland (GNOME-style libadwaita title bar).
OQ=${OQ:-$(cd "$(dirname "$0")/../.." && pwd)}   # workspace containing build/stage
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-wayland}
export QT_WAYLAND_DECORATION=${QT_WAYLAND_DECORATION:-adwaita}
exec "$OQ/build/stage/app/bin/rv" "$@"
