#!/bin/bash
# Play one file with the rv build under weston (headless) and take 3 screenshots.
# usage: run1.sh NAME FILE        env: OQ (workspace with run_rv_wayland.sh), OUT (default ./shots), WL_SOCKET (wl-test)
# weston must already run:  XDG_RUNTIME_DIR=/run/user/$(id -u) weston --debug --backend=headless --renderer=gl --width=1280 --height=800 --socket=wl-test &
# Screenshots are upside down (weston-screenshooter) and flipped with ImageMagick.
OQ=${OQ:?set OQ to the workspace directory}
OUT=${OUT:-$PWD/shots}; mkdir -p "$OUT"
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WL_SOCKET:-wl-test}

setsid nohup "$OQ/src/wayland-fedora/run_rv_wayland.sh" "$2" -play > "$OUT/$1.log" 2>&1 < /dev/null &
RVPID=$!
sleep 10
cd "$OUT"
for i in 1 2 3; do
  timeout 15 weston-screenshooter >/dev/null 2>&1
  f=$(ls -t wayland-screenshot-*.png 2>/dev/null | head -1)
  [ -n "$f" ] && magick "$f" -flip "${1}_$i.png" && rm "$f"
  sleep 0.5
done
sleep 8
echo "alive: $(pgrep -x rv.bin | head -1)"      # empty = rv died
pkill -x rv.bin
