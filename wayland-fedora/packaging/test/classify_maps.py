#!/usr/bin/env python3
"""
classify_maps.py <openrv-root> <excludelist> <maps.txt>
Reads the output of smoke.sh (paths mapped by rv.bin and its QtWebEngineProcess children) and sorts every
mapped path that is NOT inside the package:
  A  direct system lib  : soname matches the packaging deny list (glibc, GPU, Wayland, X11, dbus, audio, fonts ...)
  B  private dependency : loaded only because a class-A/C system library needs it (libsndfile->FLAC/ogg, freetype->brotli ...)
  C  GPU driver payload : dlopen'ed by Mesa/NVIDIA/glvnd (libnvidia-*, libEGL_*, libgallium, libLLVM, vulkan ICDs ...)
  W  Widevine CDM that Chromium picks up from /opt/google/chrome if Chrome is installed (DRM plugin, not a library of ours)
  D  data / non-library : caches, locale, /dev, memfd, shm
  X  VIOLATION          : anything else (e.g. a Qt, FFmpeg or ICU library of the host)
Exit status 1 if any X.
"""
import os, re, subprocess, sys
root, denyf, mapsf = sys.argv[1:4]
deny = [re.compile(l.strip()) for l in open(denyf) if l.strip() and not l.startswith('#')]
drv = re.compile(r'^(libnvidia|libEGL_|libGLX_|libgallium|libvulkan_|libVkLayer|libdisplay-info|libpciaccess|libsensors|libelf|libSPIRV|libLLVM|libdrm|libva|libxcb-)')
paths = sorted({l.strip().replace('/tmp/.real64/', '/usr/lib64/') for l in open(mapsf) if l.startswith('/') and not l.startswith('==')})  # .real64 = bind of /usr/lib64 made by hide_system_libs.sh
out = [p for p in paths if not os.path.realpath(p).startswith(os.path.realpath(root) + os.sep)]
def soname(p):
    r = subprocess.run(['readelf', '-d', p], capture_output=True, text=True).stdout
    m = re.search(r'\(SONAME\).*\[(.*)\]', r)
    return m.group(1) if m else os.path.basename(p)
def is_lib(p):
    return re.search(r'\.so(\.|$)', p) is not None
def needs(p):
    r = subprocess.run(['readelf', '-d', p], capture_output=True, text=True).stdout
    return set(re.findall(r'\(NEEDED\).*\[(.*)\]', r))
cls = {}
libs = [p for p in out if is_lib(p) and p.startswith(('/usr/lib64', '/lib64', '/usr/lib/'))]
for p in out:
    if p.startswith('/opt/google/chrome/WidevineCdm/'):
        cls[p] = 'W'
    elif not is_lib(p) or not p.startswith(('/usr/lib64/', '/lib64/', '/usr/lib/')):
        cls[p] = 'D'
    elif any(r.match(soname(p)) for r in deny):
        cls[p] = 'A'
    elif drv.match(soname(p)):
        cls[p] = 'C'
# B: needed (transitively) by an A/C library that is itself mapped
def base(p): return os.path.basename(p)
changed = True
while changed:
    changed = False
    wanted = set()
    for p, c in list(cls.items()):
        if c in 'ACB' and is_lib(p) and os.path.exists(p):
            wanted |= needs(p)
    for p in libs:
        if p not in cls:
            names = {base(p)} | {base(os.path.realpath(p))}
            # soname = filename without the trailing .x.y minor part
            names |= {re.sub(r'(\.so\.\d+)(\.[\d.]+)+$', r'\1', base(p))}
            if names & wanted:
                cls[p] = 'B'; changed = True
for p in out:
    cls.setdefault(p, 'X')
title = {'A': 'system library on the deny list', 'B': 'private dependency of a system library', 'C': 'GPU driver payload',
         'W': 'optional Widevine CDM of an installed Google Chrome (Chromium plugin lookup)', 'D': 'data / device / non-library', 'X': 'VIOLATION'}
for c in 'ABCWDX':
    ps = [p for p in out if cls[p] == c]
    if c == 'D':
        ps = [p for p in ps if not p.startswith(('/usr/lib/fontconfig/cache', '/usr/lib/locale'))]
        print('%s %-40s %d (fontconfig/locale caches omitted)' % (c, title[c], len(ps)))
        continue
    print('%s %-40s %d' % (c, title[c], len(ps)))
    for p in ps: print('     ' + p)
print('inside the package: %d paths' % (len(paths) - len(out)))
sys.exit(1 if any(v == 'X' for v in cls.values()) else 0)
