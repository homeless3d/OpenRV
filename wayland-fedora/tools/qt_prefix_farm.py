#!/usr/bin/env python3
"""Assemble the system-Qt prefix used as -DRV_DEPS_QT_LOCATION (called by make_qt_prefix.sh).

usage: qt_prefix_farm.py ROOT PREFIX QTVER
  ROOT    directory where the -devel rpms were unpacked (ROOT/usr/...)
  PREFIX  prefix to create (deleted first)
  QTVER   installed Qt version, e.g. 6.11.2

Layout (verified against the hand-made prefix of the first build, see BUILD_NOTES.md):
  include/                     symlink farm over ROOT/usr/include
  lib64/qt6/**                 symlink farm over /usr/lib64/qt6 (runtime, wins) + ROOT/usr/lib64/qt6 (devel)
  lib64/libQt6*, libclang*...  links to /usr/lib64 (runtime) or ROOT (devel only files)
  lib64/cmake                  REAL copy of the cmake dirs (CMake derives _IMPORT_PREFIX from the real location of the
                               *Targets.cmake files; symlinks would make it point into ROOT/usr instead of PREFIX)
  lib/                         REAL dir with libQt6*.so.6[.x.y] links into ../lib64 and cmake -> ../lib64/cmake
                               (qt6.cmake copies lib/; a plain `lib -> lib64` symlink clashed with other deps' cmake dirs)
  libexec/ resources/ translations/   REAL dirs of links (file(COPY) cannot duplicate a dir symlink onto an existing dir)
  share/qt6/*                  links to /usr/share/qt6/* (PySide6 --standalone copies share/qt6/resources)
  lib64/qt6/bin/qtpaths        private COPY of the system qtpaths + qt.conf (Prefix=PREFIX, Headers=include/qt6, ...)
                               so that PySide6's `--qtpaths` finds the private headers here and not in /usr
  stubs                        never-executed placeholders for imported-but-absent tools (qdoc, qhelpgenerator,
                               qtattributionsscanner, libQt6QmlFormat.a, every file named by LLVMExports/ClangTargets)
"""
import glob, os, re, shutil, stat, sys

ROOT, PREFIX, QTVER = (os.path.abspath(a) if i < 2 else a for i, a in enumerate(sys.argv[1:4]))
RU = ROOT + "/usr"
SYS = "/usr"


def farm(dst, srcs):
    """Merge directories `srcs` (priority order) into dst: real directories, every file / symlink / symlinked dir a
    symlink to the first source that has it."""
    for src in srcs:
        if not os.path.isdir(src):
            continue
        for dirpath, dirnames, filenames in os.walk(src):
            rel = os.path.relpath(dirpath, src)
            d = os.path.normpath(os.path.join(dst, rel))
            os.makedirs(d, exist_ok=True)
            leaves = filenames + [n for n in dirnames if os.path.islink(os.path.join(dirpath, n))]
            for n in leaves:
                t = os.path.join(d, n)
                if not os.path.lexists(t):
                    os.symlink(os.path.join(dirpath, n), t)


def link(name, dirs, dst):
    """Link dst/name to the first of dirs that has it; dangling devel symlinks (libQt6Core.so -> libQt6Core.so.6) are
    redirected to the runtime library in /usr when that exists."""
    t = os.path.join(dst, name)
    if os.path.lexists(t):
        return
    for d in dirs:
        p = os.path.join(d, name)
        if not os.path.lexists(p):
            continue
        if os.path.islink(p) and not os.path.exists(p):
            tgt = os.readlink(p)
            alt = os.path.join(SYS + "/lib64", tgt)
            if not os.path.isabs(tgt) and os.path.lexists(alt):
                p = alt
        os.symlink(p, t)
        return


def stub(path, text, mode=0o755):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.lexists(path):
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, mode)


SH_STUB = "#!/bin/sh\nexit 1\n"
AR_STUB = "!<arch>\n"

# ------------------------------------------------------------------ 0. LLVM/clang tree in ROOT (for shiboken6)
llvm_dirs = sorted(glob.glob(RU + "/lib64/llvm[0-9]*"))
if llvm_dirs:
    ld = llvm_dirs[0]
    major = re.sub(r"\D", "", os.path.basename(ld))
    if not os.path.lexists(ld + "/lib"):
        os.symlink("lib64", ld + "/lib")
    # clang's resource dir (stddef.h ...) lives in the installed clang-resource-dir package
    res = ld + "/lib64/clang/" + major
    os.makedirs(res, exist_ok=True)
    if not os.path.lexists(res + "/include"):
        os.symlink("/usr/lib/clang/%s/include" % major, res + "/include")
    # libLLVM.so (devel) -> libLLVM.so.NN.x lives in llvm-libs (installed): point at the system copy
    for so in glob.glob(RU + "/lib64/libLLVM.so"):
        tgt = os.readlink(so) if os.path.islink(so) else None
        if tgt and not os.path.lexists(os.path.join(RU, "lib64", tgt)):
            os.symlink("/usr/lib64/" + tgt, os.path.join(RU, "lib64", tgt))
    for so in glob.glob("/usr/lib64/libclang*.so.*") + glob.glob("/usr/lib64/libLLVM*.so.*"):
        t = os.path.join(RU, "lib64", os.path.basename(so))
        if not os.path.lexists(t):
            os.symlink(so, t)
    # LLVMExports / ClangTargets name static libs and tools that no installed package provides
    n = 0
    for cm in glob.glob(RU + "/lib64/cmake/llvm/*.cmake") + glob.glob(RU + "/lib64/cmake/clang/*.cmake"):
        for m in re.finditer(r"\$\{_IMPORT_PREFIX\}/((?:bin|lib64)/[^\"; )]+)", open(cm, errors="replace").read()):
            rel = m.group(1)
            if rel.endswith("/") or os.path.lexists(os.path.join(RU, rel)):
                continue
            stub(os.path.join(RU, rel), AR_STUB if rel.endswith(".a") else SH_STUB)
            n += 1
    print("llvm: %s, %d stub files" % (os.path.basename(ld), n))

# ------------------------------------------------------------------ 1. the prefix
if os.path.lexists(PREFIX):
    shutil.rmtree(PREFIX)
for d in ("include", "lib64/qt6", "lib64/pkgconfig", "lib", "libexec", "resources", "translations", "share/qt6"):
    os.makedirs(os.path.join(PREFIX, d), exist_ok=True)

farm(PREFIX + "/include", [RU + "/include"])
farm(PREFIX + "/lib64/qt6", [SYS + "/lib64/qt6", RU + "/lib64/qt6"])
for d in ("cmake", "examples", "imports"):
    os.makedirs(PREFIX + "/lib64/qt6/" + d, exist_ok=True)

# top of lib64
names = set()
for base in (SYS + "/lib64", RU + "/lib64"):
    for n in os.listdir(base):
        if n.startswith(("libQt6", "libclang")) or n == "libLLVM.so" or re.match(r"libLLVM\.so\.", n):
            names.add(n)
for n in sorted(names):
    link(n, [SYS + "/lib64", RU + "/lib64"], PREFIX + "/lib64")
for n in os.listdir(RU + "/lib64/pkgconfig") if os.path.isdir(RU + "/lib64/pkgconfig") else []:
    link(n, [RU + "/lib64/pkgconfig"], PREFIX + "/lib64/pkgconfig")
for p in glob.glob(SYS + "/lib64/pkgconfig/Qt6*.pc"):
    link(os.path.basename(p), [SYS + "/lib64/pkgconfig"], PREFIX + "/lib64/pkgconfig")

# llvmNN tree (the RV_PYSIDE_SYSTEM_LLVM_DIR copy is the one in ROOT; this keeps a prefix-relative one for cmake find_package)
for ld in llvm_dirs:
    farm(PREFIX + "/lib64/" + os.path.basename(ld), [ld])

# cmake dirs: real copies (see docstring)
for src in (RU + "/lib64/cmake",):
    if os.path.isdir(src):
        shutil.copytree(src, PREFIX + "/lib64/cmake", symlinks=True, dirs_exist_ok=True)
for p in glob.glob(SYS + "/lib64/cmake/Qt6*"):
    t = PREFIX + "/lib64/cmake/" + os.path.basename(p)
    if not os.path.exists(t):
        shutil.copytree(p, t, symlinks=True)

# lib/: real dir of links to ../lib64
for n in sorted(os.listdir(PREFIX + "/lib64")):
    if re.match(r"libQt6.*\.so\.6(\..*)?$", n):
        os.symlink("../lib64/" + n, PREFIX + "/lib/" + n)
os.symlink("../lib64/cmake", PREFIX + "/lib/cmake")

# resources / translations: real dirs of links (libexec/ is filled at the end, after the stubs exist)
for sub in ("resources", "translations"):
    for n in os.listdir(SYS + "/share/qt6/" + sub):
        os.symlink(SYS + "/share/qt6/%s/%s" % (sub, n), "%s/%s/%s" % (PREFIX, sub, n))

# share
if os.path.isdir(RU + "/share/qt6"):          # e.g. json_schema (real dir of links)
    farm(PREFIX + "/share/qt6", [RU + "/share/qt6"])
for n in os.listdir(SYS + "/share/qt6"):
    t = PREFIX + "/share/qt6/" + n
    if not os.path.lexists(t):
        os.symlink(SYS + "/share/qt6/" + n, t)
for sub in ("licenses", "man", "clang"):
    if os.path.isdir(RU + "/share/" + sub):
        farm(PREFIX + "/share/" + sub, [RU + "/share/" + sub])

os.symlink("lib64/qt6/bin", PREFIX + "/bin")
os.symlink("lib64/qt6/plugins", PREFIX + "/plugins")

# ------------------------------------------------------------------ 2. fixes
# qtpaths: private copy + qt.conf so it reports PREFIX
bindir = PREFIX + "/lib64/qt6/bin"
for n in ("qtpaths", "qtpaths6"):
    t = os.path.join(bindir, n)
    if os.path.lexists(t) or os.path.exists(SYS + "/lib64/qt6/bin/" + n):
        if os.path.lexists(t):
            os.unlink(t)
        shutil.copy2(SYS + "/lib64/qt6/bin/" + n, t)
with open(bindir + "/qt.conf", "w") as f:
    f.write("""[Paths]
Prefix = %(p)s
ArchData = lib64/qt6
Binaries = lib64/qt6/bin
LibraryExecutables = lib64/qt6/libexec
Libraries = lib64
Headers = include/qt6
Plugins = lib64/qt6/plugins
Qml2Imports = lib64/qt6/qml
Data = share/qt6
Translations = translations
Examples = lib64/qt6/examples
HostPrefix = %(p)s
HostData = lib64/qt6
HostBinaries = lib64/qt6/bin
HostLibraries = lib64
HostLibraryExecutables = lib64/qt6/libexec
""" % {"p": PREFIX})

# placeholders for tools/libs that the Qt6 cmake config imports but no installed/downloaded package supplies
MSG = '#!/bin/sh\necho "stub: not available in system-Qt prefix" >&2\nexit 1\n'
for rel in ("lib64/qt6/libexec/qhelpgenerator", "lib64/qt6/libexec/qtattributionsscanner", "lib64/qt6/bin/qdoc"):
    t = os.path.join(PREFIX, rel)
    if os.path.islink(t):
        if os.path.exists(t):
            continue
        os.unlink(t)
    stub(t, MSG)
for n in os.listdir(PREFIX + "/lib64/qt6/libexec"):
    os.symlink("../lib64/qt6/libexec/" + n, PREFIX + "/libexec/" + n)
stub(PREFIX + "/lib64/libQt6QmlFormat.a", AR_STUB, 0o644)

print("prefix ready: %s (Qt %s)" % (PREFIX, QTVER))
