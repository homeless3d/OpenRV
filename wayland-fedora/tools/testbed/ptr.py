# Drive the pointer of the private headless mutter through org.gnome.Mutter.RemoteDesktop.
# usage: ptr.py "home; to 640 400; sleep 1; down; drag 10 0 30; up"   (commands separated by ';')
import sys, time
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def call(path, iface, method, args=None, sig=None):
    return bus.call_sync("org.gnome.Mutter.RemoteDesktop", path, iface, method, args, sig and GLib.VariantType(sig), 0, -1, None)
sp = call("/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop", "CreateSession", None, "(o)").unpack()[0]
S = "org.gnome.Mutter.RemoteDesktop.Session"
call(sp, S, "Start")
BTN_LEFT = 272
pos = [0, 0]
def rel(dx, dy):
    call(sp, S, "NotifyPointerMotionRelative", GLib.Variant("(dd)", (float(dx), float(dy))))
for cmd in sys.argv[1].split(";"):
    w = cmd.split()
    if not w: continue
    if w[0] == "home": rel(-10000, -10000); pos = [0, 0]
    elif w[0] == "to":
        x, y = int(w[1]), int(w[2]); rel(x - pos[0], y - pos[1]); pos = [x, y]
    elif w[0] == "down": call(sp, S, "NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, True)))
    elif w[0] == "up": call(sp, S, "NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, False)))
    elif w[0] == "drag":   # drag dx dy steps
        dx, dy, n = int(w[1]), int(w[2]), int(w[3])
        for i in range(n):
            rel(dx, dy); pos = [pos[0] + dx, pos[1] + dy]; time.sleep(0.03)
    elif w[0] == "rdown": call(sp, S, "NotifyPointerButton", GLib.Variant("(ib)", (273, True)))
    elif w[0] == "rup": call(sp, S, "NotifyPointerButton", GLib.Variant("(ib)", (273, False)))
    elif w[0] == "sleep": time.sleep(float(w[1]))
    print("PTR", cmd.strip(), "->", pos, flush=True)
    time.sleep(0.05)
call(sp, S, "Stop")
