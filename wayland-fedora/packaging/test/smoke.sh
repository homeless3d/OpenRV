#!/bin/bash
# smoke.sh <openrv-root> <outdir> <seconds> [rv args...]
# Runs the packaged rv with a SCRUBBED environment on the given Wayland socket, then records
# /proc/<pid>/maps of rv.bin and its QtWebEngineProcess children and a weston screenshot.
# env: WL (wayland socket, default wl-pk; set WL= empty for the X11 fallback test with DX=:97), DX (X display for the xcb fallback), SHOT=0 to skip screenshot
ROOT=$1; OUT=$2; SECS=$3; shift 3
WL=${WL-wl-pk}; mkdir -p "$OUT"
LOG=$OUT/run.log; : > "$LOG"
env -i HOME="$HOME" XDG_RUNTIME_DIR="${XRD:-/run/user/$(id -u)}" ${WL:+WAYLAND_DISPLAY=$WL} ${DX:+DISPLAY=$DX} PATH=/usr/bin:/bin \
    ${EXTRA_ENV} "$ROOT/bin/rv" "$@" > "$LOG" 2>&1 &
W=$!
P=
for i in $(seq 1 90); do P=$(pgrep -x rv.bin | head -1); [ -n "$P" ] && break; sleep 1; done
echo "rv.bin pid: ${P:-none} (after ${i}s)"
sleep "$SECS"
if [ -n "$P" ] && [ -d /proc/$P ]; then
    for pid in $P $(pgrep -P $P); do
        echo "== pid $pid $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-120)" >> "$OUT/maps.txt"
        awk '$6 ~ /^\// {print $6}' /proc/$pid/maps | sort -u >> "$OUT/maps.txt"
    done
    if [ "${SHOT:-1}" = 1 ] && [ -z "$WL" ] && [ -n "$DX" ]; then      # X11 session: grab the X display
        DISPLAY=$DX import -window root "$OUT/shot.png" 2>/dev/null
    elif [ "${SHOT:-1}" = 1 ]; then
        ( cd "$OUT" && rm -f wayland-screenshot*.png && WAYLAND_DISPLAY=$WL XDG_RUNTIME_DIR=/run/user/$(id -u) timeout 20 weston-screenshooter >/dev/null 2>&1
          f=$(ls -t wayland-screenshot*.png 2>/dev/null | head -1); [ -n "$f" ] && magick "$f" -flip "$OUT/shot.png" && rm -f "$f" )
    fi
    kill $P 2>/dev/null; sleep 2; kill -9 $P 2>/dev/null
fi
wait $W 2>/dev/null
echo "log: $LOG"
