#!/bin/bash
# Headless mutter (the real GNOME compositor) on its own Wayland socket and private D-Bus session.
# Run it through dbus-run-session so that it gets a private bus:
#     dbus-run-session -- ./start_mutter.sh &
# Env: WL_SOCKET (default wl-mut), RUN_DIR (where bus.addr / mutter.log go, default ./run),
#      SIZE (default 1280x800), XDG_RUNTIME_DIR (default /run/user/$(id -u)).
# bus.addr holds the private bus address; export DBUS_SESSION_BUS_ADDRESS=$(cat run/bus.addr) before ptr.py.
RUN_DIR=${RUN_DIR:-$PWD/run}; mkdir -p "$RUN_DIR"
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
unset WAYLAND_DISPLAY DISPLAY
echo "$DBUS_SESSION_BUS_ADDRESS" > "$RUN_DIR/bus.addr"
exec mutter --headless --wayland --no-x11 --wayland-display="${WL_SOCKET:-wl-mut}" \
     --virtual-monitor "${SIZE:-1280x800}" > "$RUN_DIR/mutter.log" 2>&1
