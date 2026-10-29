# Headless test bed (weston / mutter / Xvfb)

Why: a real GNOME session cannot be screenshotted or driven from a build environment, so the Wayland behaviour was checked on private
compositors. None of this replaces a test on a real session.

| Script | Purpose |
|---|---|
| `run1.sh NAME FILE` | play FILE with the built rv under a running weston headless, 3 screenshots (`OQ=...` required) |
| `start_mutter.sh` | headless **mutter** (GNOME's compositor) on its own socket and private D-Bus: `dbus-run-session -- ./start_mutter.sh &` |
| `ptr.py "home; to 640 400; down; drag 10 0 30; up"` | drive mutter's pointer through `org.gnome.Mutter.RemoteDesktop` (system `python3` with `gi`; `DBUS_SESSION_BUS_ADDRESS=$(cat run/bus.addr)`) |
| `probe.py` | load into rv with `-pyeval` (`PROBE_OUT=file`): logs the mouse events the viewport window receives and the current frame |
| `make_jpg_seq.py [dir] [n]` | numbered colour test sequence `f.0001.jpg ...` |
| `make_movies.py` | `test.mp4` (H.264) and `test.mov` (mpeg4) from that sequence (PyAV) |
| `make_codec_movies.py` | H.264+AAC, HEVC, ProRes 422 10-bit, H.264 with B-frames (PyAV) |

## weston (screenshots)

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
weston --debug --backend=headless --renderer=gl --width=1280 --height=800 --socket=wl-test &   # --debug is required for weston-screenshooter
export OQ=$HOME/openrv-qt6; ./run1.sh mp4 data/mov/test.mp4      # shots/mp4_{1,2,3}.png, upside down -> run1.sh flips them
```
`weston-screenshooter` sometimes hangs: kill that weston by pid and start a new one.

## mutter (input; no screenshots)

```bash
dbus-run-session -- ./start_mutter.sh &        # wl-mut socket; bus address in run/bus.addr
export DBUS_SESSION_BUS_ADDRESS=$(cat run/bus.addr) XDG_RUNTIME_DIR=/run/user/$(id -u)
WAYLAND_DISPLAY=wl-mut PROBE_OUT=$PWD/probe.out $OQ/src/wayland-fedora/run_rv_wayland.sh seq.0001.jpg -pyeval "exec(open('$PWD/probe.py').read())" &
python3 ptr.py "home; to 300 700; down; drag 4 0 80; drag 0 40 3; up"       # scrub, then leave the window
```
Keep ONE RemoteDesktop session per gesture (stopping it removes the seat's pointer); relative motion is 1:1 and clamps at 0,0 (`home`).
Read `probe.out`: `press`, `move` (with `buttons=` and `frame=`), and no `leave`/`buttons=0` until the release means patch 0003 works.
