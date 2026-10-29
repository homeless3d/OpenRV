#!/usr/bin/env python3
"""
closure.py -- bundle the non-core shared-library closure of an OpenRV tree.

usage: closure.py APPDIR DENYLIST EXTRAS [--verify]

  APPDIR    the application tree (bin/, lib/, plugins/ ...), modified in place
  DENYLIST  file with one ERE per line (matched against a SONAME with re.match):
            libraries that must stay SYSTEM provided and are never copied
  EXTRAS    file with one glob per line (resolved against the host's library
            dirs): libraries that are dlopen()ed and therefore invisible to ldd

Algorithm (AppImage "excludelist" approach):
  1. every ELF file inside APPDIR is run through ldd with
     LD_LIBRARY_PATH=APPDIR/lib:APPDIR/lib/OpenSSL
  2. every dependency that resolves OUTSIDE APPDIR (host /usr/lib64, a build
     tree, ...) and is not on the deny list is copied as APPDIR/lib/<soname>
     and becomes part of the next round (transitive closure)
  3. the dependencies that are on the deny list are recorded (system.txt)
  4. RUNPATH of every ELF is then set by set_runpath.sh to $ORIGIN-relative
     directories only (done by the caller with patchelf).

--verify: no copying; ldd with an EMPTY library path and report what resolves
          outside APPDIR (must all be deny-listed, i.e. the runtime system list).
"""
import collections, glob, os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

app, denyf, extrasf = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3]
verify = '--verify' in sys.argv
deny = [re.compile(l.strip()) for l in open(denyf)
        if l.strip() and not l.startswith('#')]
LIB = os.path.join(app, 'lib')
REPORT = os.environ.get('REPORT_DIR', os.path.dirname(app))


def denied(so):
    return any(r.match(so) for r in deny)


def elf_files(root):
    out = []
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p):
                continue
            try:
                with open(p, 'rb') as fh:
                    if fh.read(4) == b'\x7fELF':
                        out.append(p)
            except OSError:
                pass
    return out


def ldd(p, env):
    r = subprocess.run(['ldd', p], capture_output=True, text=True, env=env)
    deps = []
    for l in r.stdout.splitlines():
        l = l.strip()
        if '=>' not in l:
            continue
        n, _, rest = l.partition('=>')
        rest = rest.strip()
        path = 'not found' if rest.startswith('not found') else rest.split(' (')[0].strip()
        deps.append((n.strip(), path))
    return p, deps


def scan(files, env):
    res = collections.defaultdict(set)   # (soname, path) -> users
    with ThreadPoolExecutor(12) as ex:
        for p, deps in ex.map(lambda f: ldd(f, env), files):
            for n, path in deps:
                res[(n, path)].add(os.path.relpath(p, app))
    return res


def inside(path):
    return os.path.realpath(path).startswith(app + os.sep) if path != 'not found' else False


env = {k: v for k, v in os.environ.items() if k not in ('LD_LIBRARY_PATH', 'LD_PRELOAD')}
if not verify:
    env['LD_LIBRARY_PATH'] = LIB + ':' + os.path.join(LIB, 'OpenSSL')

def needed(p):
    """(NEEDED sonames, expanded RPATH/RUNPATH dirs) of one ELF, from readelf -d"""
    out = subprocess.run(['readelf', '-d', p], capture_output=True, text=True).stdout
    need, dirs = [], []
    for l in out.splitlines():
        m = re.search(r'\(NEEDED\).*\[(.*)\]', l)
        if m:
            need.append(m.group(1))
        m = re.search(r'\((RUNPATH|RPATH)\).*\[(.*)\]', l)
        if m:
            dirs += [d.replace('$ORIGIN', os.path.dirname(p)) for d in m.group(2).split(':') if d]
    return need, dirs


if verify:
    # direct NEEDED edges only (ldd would also list the private dependencies of the system libraries):
    # each must be found through the file's own RUNPATH inside the tree, or be on the deny list.
    system, missing = collections.defaultdict(set), collections.defaultdict(set)
    files = elf_files(app)
    with ThreadPoolExecutor(12) as ex:
        for p, (need, dirs) in zip(files, ex.map(needed, files)):
            for n in need:
                if any(os.path.exists(os.path.join(d, n)) and os.path.realpath(os.path.join(d, n)).startswith(app + os.sep) for d in dirs):
                    continue
                (system if denied(n) else missing)[n].add(os.path.relpath(p, app))
    with open(os.path.join(REPORT, 'system-libs.txt'), 'w') as f:
        for n in sorted(system):
            f.write('%s\t%d users, e.g. %s\n' % (n, len(system[n]), sorted(system[n])[0]))
    print('direct system-library dependencies (all deny-listed): %d' % len(system))
    print('bundled-or-system violations (NEEDED, not found via RUNPATH, not deny-listed): %s'
          % ({k: sorted(v)[:2] for k, v in missing.items()} or 'none'))
    sys.exit(1 if missing else 0)

os.makedirs(LIB, exist_ok=True)
copied = {}
seen_files = set()
denied_seen = collections.defaultdict(set)


def host_copy(so, src):
    dst = os.path.join(LIB, so)
    if os.path.exists(dst):
        return False
    shutil.copy2(os.path.realpath(src), dst)
    os.chmod(dst, 0o755)
    copied[so] = os.path.realpath(src)
    return True


# dlopen()ed libraries (listed explicitly)
dirs = ['/usr/lib64', '/lib64']
for line in open(extrasf):
    g = line.strip()
    if not g or g.startswith('#'):
        continue
    hit = [h for d in dirs for h in glob.glob(os.path.join(d, g))]
    if not hit:
        print('WARNING: extra %s not found on host' % g)
    for h in hit:
        host_copy(os.path.basename(h), h)

round_ = 0
while True:
    round_ += 1
    files = [f for f in elf_files(app) if f not in seen_files]
    if not files:
        break
    seen_files.update(files)
    res = scan(files, env)
    new = 0
    for (n, path), users in sorted(res.items()):
        if path == 'not found':
            print('UNRESOLVED %s (needed by %s)' % (n, sorted(users)[:3]))
            continue
        if inside(path):
            continue
        if denied(n):
            denied_seen[n] |= users
            continue
        if host_copy(n, path):
            new += 1
    print('round %d: scanned %d files, copied %d new libs' % (round_, len(files), new))

with open(os.path.join(REPORT, 'bundled-libs.txt'), 'w') as f:
    for so, src in sorted(copied.items()):
        f.write('%s\t%s\n' % (so, src))
with open(os.path.join(REPORT, 'denied-seen.txt'), 'w') as f:
    for n in sorted(denied_seen):
        f.write('%s\t%s\n' % (n, ','.join(sorted(denied_seen[n])[:2])))
print('bundled %d libs from the host; %d deny-listed sonames seen' % (len(copied), len(denied_seen)))
