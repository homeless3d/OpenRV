# run inside rv:  rv -pyeval "exec(open('/path/webview_probe.py').read())" movie.mp4
# creates a QtWebEngine page (spawns the bundled QtWebEngineProcess), reports where PySide6/Qt came from
import os
from PySide6 import QtCore, QtWidgets, QtWebEngineWidgets, QtWebEngineCore
OUT = os.environ.get('WEBPROBE_OUT', '/tmp/webprobe.txt')
f = open(OUT, 'w')
def w(s):
    f.write(s + '\n'); f.flush()
w('PySide6 QtCore: ' + QtCore.__file__)
w('PySide6 QtWebEngineWidgets: ' + QtWebEngineWidgets.__file__)
w('Qt runtime version: ' + QtCore.qVersion())
w('plugins path: ' + str(QtCore.QLibraryInfo.path(QtCore.QLibraryInfo.PluginsPath)))
w('libexec path: ' + str(QtCore.QLibraryInfo.path(QtCore.QLibraryInfo.LibraryExecutablesPath)))
w('data path: ' + str(QtCore.QLibraryInfo.path(QtCore.QLibraryInfo.DataPath)))
v = QtWebEngineWidgets.QWebEngineView()
v.setWindowTitle('WEBENGINE PANEL TEST')
v.resize(520, 220)
v.loadFinished.connect(lambda ok: w('loadFinished ok=%s title=%s' % (ok, v.title())))
v.setHtml("<html><head><title>pkgtest</title></head><body style='background:#1d8a5a;color:white;font:40px sans-serif'>WebEngine OK</body></html>")
v.show()
globals()['_keep_webview'] = v
