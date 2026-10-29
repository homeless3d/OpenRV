# Loaded into RV via -pyeval (PROBE_OUT=file selects the log, default ./probe.out): logs mouse events seen by the viewport QWindow and the current frame.
import os, sys, time
from PySide6.QtCore import QObject, QEvent, QTimer
from PySide6.QtGui import QGuiApplication
from rv import commands
T0 = time.time()
_out = open(os.environ.get("PROBE_OUT", "probe.out"), "a")
def log(*a):
    _out.write("PROBE %.3f %s\n" % (time.time() - T0, " ".join(str(x) for x in a))); _out.flush()
NAMES = {QEvent.MouseMove: "move", QEvent.MouseButtonPress: "press", QEvent.MouseButtonRelease: "release",
         QEvent.Enter: "enter", QEvent.Leave: "leave"}
class F(QObject):
    def eventFilter(self, obj, ev):
        t = ev.type()
        if t in NAMES:
            if t in (QEvent.Enter, QEvent.Leave):
                log(obj.metaObject().className(), NAMES[t])
            else:
                p = ev.position()
                log(obj.metaObject().className(), NAMES[t], "pos=%d,%d" % (p.x(), p.y()), "buttons=%d" % int(ev.buttons().value), "frame=%d" % commands.frame())
        return False
_f = F()
_done = set()
def attach():
    for w in QGuiApplication.allWindows():
        n = w.metaObject().className()
        if id(w) not in _done and n in ("Rv::GLWindow", "QWidgetWindow"):
            _done.add(id(w)); w.installEventFilter(_f); log("attached", n, w.width(), w.height())
QTimer.singleShot(3000, attach)
_t = QTimer(); _t.timeout.connect(lambda: log("frame", commands.frame())); _t.start(250)
