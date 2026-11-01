# Startup performance

Goal: shorten the time from launching `rv` to a usable window, on the installed, self-contained rpm. All numbers
below are from one machine (Fedora 44, NVIDIA) and one small test session; treat them as relative, not as
benchmarks. "First frame" = time to the first rendered frame of the main window. "Idle" = time until the process stops
doing startup work (CPU quiet).

## Methodology

The machine had no `perf` and no `strace` installed and nothing could be installed, so the tools were improvised:

* **Poor-man's profiler**: attach `gdb` to `rv.bin` repeatedly during startup and take the main thread's backtrace
  (repeated samples during the startup window). Frames that show up in most samples are where the time goes. Run `rv.bin` directly
  (the `bin/rv` shipped by upstream is a csh wrapper) with `RV_HOME` and `LD_LIBRARY_PATH` set.
* **Python imports**: `PYTHONPROFILEIMPORTTIME=1` prints a per-module import cost table for the embedded Python.
* **Time to first frame**: `WAYLAND_DEBUG=client` and the timestamp of the first `wl_surface.attach` carrying a buffer
  for the main window, relative to process start. Works on native Wayland in a private compositor, no screenshots
  needed.
* **Cold-cache simulation**: drop a file tree from the page cache with `posix_fadvise(POSIX_FADV_DONTNEED)` (no root
  needed, unlike writing to `/proc/sys/vm/drop_caches`) and then start `rv`; the amount of data read from disk
  was compared with and without the optimisations.
* **Interleaved runs**: A/B variants run alternately (A B A B ...) rather than in blocks, so drift in CPU frequency,
  cache state and background load affects both equally. The number of runs per variant and the statistic used (median or mean) were not recorded in the repository.

## Findings

| Finding | Evidence | Action |
|---|---|---|
| `rv.runtime` called `QWebEngineProfile.defaultProfile()` during startup, which initialises **Chromium on the main thread** (about 1 s, plus ~1.5 s of CPU across the `QtWebEngineProcess` children) even if no web view is ever shown | gdb samples and import timing during startup; the 1 s / 1.5 s figures are from the commit messages of `43cb7f1` / `0495a0f` | Defer, then make lazy (commits below) |
| **Mu sources compiled on every launch**: `/opt/openrv` is read-only for users and the package shipped no `.muc`, so the Mu compiler ran each time (and again whenever an optional package mode such as session_manager, annotate or doc_browser was switched on) | gdb samples in the Mu compiler; Mu writes `.muc` only next to the `.mu`, which users cannot write to, and has no staleness check (a `.muc` silently wins over an edited `.mu`) | Precompile in the rpm with `rv -debug compile` (build step 7b, see below) |
| `certifi` imported just to learn the CA bundle path (`sitecustomize.py`) | `PYTHONPROFILEIMPORTTIME`: ~0.2 s | Locate the file with `importlib.util.find_spec` (`bd35652`) |
| Dynamic linking (`ld.so`) | ~15 ms measured | Nothing to gain; prelink or similar is not worth it |
| AJADevices plugin load | cost 0 in samples | Left alone |
| Vulkan / GBM messages on stderr | "Failed to find vkGetPhysicalDeviceWaylandPresentationSupportKHR", "GBM is not supported" | Harmless; no time cost |
| QSS (style sheet) parsing | no measurable effect | Left alone |

## Commits

| Commit | Change | Effect reported |
|---|---|---|
| `43cb7f1` | `rv.runtime`: do the web engine user-agent setup 600 ms after startup (a `QTimer.singleShot`) instead of at import | First window on Wayland 2.3 s -> 1.3 s (as measured when it was committed) |
| `0495a0f` | `rv.runtime`: no longer scheduled at all. `setup_webview_default_profile()` imports PySide lazily, is idempotent, and is called by `webview2.py` right before it creates its `QWebEngineView`. The Mu `doc_browser` cannot call it and uses Chromium's default user agent | Chromium never starts unless a web view is shown |
| `bd35652` | `src/build/sitecustomize.py`: find `cacert.pem` next to the `certifi` package with `importlib.util.find_spec`; fall back to `certifi.where()` | ~0.2 s |
| (rpm) | `packaging/build_rpm.sh` step 7b: precompile Mu to `.muc` / `.mud` in the final tree | Mu no longer compiled at launch |

## Numbers

Warm = files in the page cache; cold = the install tree dropped from the cache with `posix_fadvise` first.

| Measure | Before | After |
|---|---|---|
| Time to first frame, warm | 1.76 s | 1.41 s |
| Time to idle, warm | 2.90 s | 1.45 s |
| Time to idle, cold | 3.70 s | 1.55 s |
| Data read from disk, cold start | 205 MB | 23 MB |

The cold-start gain is mostly data that is no longer touched (Chromium initialisation and Mu compilation). The
first-frame improvement is smaller than the idle improvement; the table does not say why, and no further analysis of
that difference was done.

## What remains inherent

* Loading **PySide6 / shiboken** (large extension modules and the Qt libraries they pull in).
* `opentimelineio` importing `urllib` and friends at import time.
* `rv.bin` links **`libQt6WebEngineCore` directly**, so its (large) library is mapped and relocated at start even
  though Chromium is no longer initialised.
* Python itself starting and importing the RV UI packages.

Removing these would need either lazy-importing deeper into the Python packages or restructuring the link of `rv.bin`;
neither was attempted.

## Round 2

Second round, done after the first one above. Two kinds of change: Python and packaging details found with the same
tools (import-time profile, per-file checks of the installed tree), and a rebuild of the packaging step that ships
Mu bytecode. Commits: `86f93c2` (lazy `opentimelineio` and `psutil`), plus the rpm-recipe changes in
[04-packaging-rpm.md](04-packaging-rpm.md) (steps 7b and 7c; the packaging copy is committed under
`wayland-fedora/packaging/`).

### Findings

| Finding | Evidence | Action |
|---|---|---|
| **Every `.pyc` in the rpm was stale.** `rpmbuild` changes file mtimes and `/opt` is root-owned, so rv could neither trust nor rewrite the `__pycache__` files: 3932 of 3965 files were out of date, and rv compiled the whole Python side in memory at every start | Python import time 749 ms -> 255 ms after the fix; this is the biggest single win of the round | Step 7c: remove all `__pycache__`, then `compileall --invalidation-mode checked-hash` with the bundled Python, after every other step that touches files |
| `opentimelineio` imported at module load by `otio_reader_plugin.py` | ~175 ms of import time | Import on first use (`86f93c2`) |
| `psutil` imported at module load by `local_thumbnail_gen.py` | ~37 ms | Import on first use (`86f93c2`) |
| Optional Mu modes compiled on first activation | e.g. `annotate_mode`, `doc_browser`, `layer_select` | Step 7b now precompiles every `plugins/Mu/*.mu` that can be (48 `.muc` + 28 `.mud` from 51 `.mu`), see below |
| Mu's `Module::load` (`src/lib/mu/Mu/Module.cpp`) writes a `.muc` only for modules actually loaded during a `-debug compile` run, and never compares mtime, size or hash | Reading the source; a readable `.muc` is used as is | The recipe loads every module explicitly; and a stale `.muc` wins over an edited `.mu`, so `.muc` are generated from the final tree |
| `rvio` overlay scripts (frameburn, watermark, matte, bug, simpleslate) with and without `.muc` | JPG output byte-identical | Nothing to do; `.muc` is safe for them |

Commits `43cb7f1`, `0495a0f` and `bd35652` belong to round 1 and are described above.

### Measurements

Warm: n = 5; cold: n = 3; copies of the install tree on an NVMe disk; variants interleaved. "Before" = the rpm
tree after round 1 (stale `.pyc`, step 7b only for the modules loaded at start); "After" = with `86f93c2`, step 7b
for all modules and step 7c. Only measured with no arguments, i.e. **no media loaded**.

| Measure | Before | After |
|---|---|---|
| Main window created | 0.655 s | 0.512 s |
| First frame, warm | 1.550 s | 0.986 s |
| First frame, cold | 1.888 s | 1.350 s |
| Idle, warm | 1.81 s | 1.06 s |
| Idle, cold | 1.95 s | 1.42 s |
| CPU time per start | 1.6 s | 1.1 s |
| Python import time | 749 ms | 255 ms |

Combined from the original rpm (first frame 1.76 s in the first-round table) to now: about **0.99 s warm**.

First activation of optional Mu modes with `.muc` (mean of 5):

| Mode | Without `.muc` | With `.muc` |
|---|---|---|
| `annotate_mode` | 227 ms | 173 ms |
| `doc_browser` | 920 ms | 876 ms (QtWebEngine dominates) |
| `export_cuts` | 29 ms | 21 ms |
| `layer_select` | 11 ms | 3 ms |

Caveats:

* Earlier **cold** numbers made with `posix_fadvise(DONTNEED)` were **unreliable** because the scratch directory was on
  tmpfs (the call does nothing useful there). The cold numbers above are from NVMe copies; the round-1 cold numbers
  (table above) used the earlier method and should be read with that in mind.
* The gain of the `.pyc` fix and the gain of the lazy imports were **not separated** in the end-to-end numbers (the
  import-time figure 749 -> 255 ms comes from the `.pyc` fix; the lazy imports save their ~0.2 s on top).
* Startup **with media loaded** was not measured.

### Tried and rejected (no gain)

* Prefetching files from the wrapper (`cat` / `posix_fadvise(WILLNEED)`).
* A PySide6 preload thread.
* Skipping the AJADevices plugin (0 gain).
* Removing the QSS (noise).
* prelink / `-z now` (`ld.so` is only ~15 ms).
* `--disable-gpu` / Vulkan flags for Chromium (~0.2 s only).
* Running Python initialisation in another thread: not viable (GIL; PySide6, Mu and Python must run on the main
  thread).

### Not done

* `multiprocessing` is imported because of `PyInterface.cpp` (50-95 ms); needs a C++ rebuild.
* `from PySide6 import *` in `rv.qtutils` (~100 ms); removing it would change a public API of the RV Python modules.
* Lazy loading of Mu modules, a thread pool for icon decoding, a fontconfig cache, splitting the package scan: not
  evaluated.
* `doc_browser.mu` is Mu and cannot call the Python user-agent setup, so it uses Chromium's default user agent without
  the " RV/4.0.0" suffix (`webview2` sets it before creating its view). See [06-open-issues.md](06-open-issues.md).

### Mu precompile in the rpm: what is known

* `rv -debug compile` writes `.muc` (bytecode) and `.mud` (docs) next to each `.mu` loaded during the run.
* Excluded on purpose (`MUC_EXCLUDE`): `external_ioprocess` (compiling it segfaults in `Archive::Writer::freeze`,
  nothing loads it), `maya_tools` and `rvnuke_mode` (they compile, but loading their `.muc` in a new process segfaults;
  **cause not found**). All three still work from source.
* No display, no compile: the Qt platforms `offscreen` and `minimal` abort (rc 134) and `mu-interp` lacks the
  `commands` module. Display selection is described in [04-packaging-rpm.md](04-packaging-rpm.md).
