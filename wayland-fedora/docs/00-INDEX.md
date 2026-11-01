# OpenRV on Wayland with the system Qt 6 (Fedora): documentation index

## Summary

This project ports **OpenRV** (the Apache-2.0 release of the RV review player, ASWF) to run **natively on Wayland**
on **Fedora 44**, built against the **system Qt 6.11.2** instead of the Qt 5.15 / Qt 6.8 binaries that upstream
downloads. The base is upstream `main` at commit `cade394` ("4.0.0", VFX Reference Platform CY2026); the work is a
small set of commits on top of it (branch `wayland-qt6`), plus scripts, patches and an rpm recipe under
`wayland-fedora/`. It exists because the author wanted a modern, GNOME-native RV on a current Fedora, with a
maintainable path to follow upstream and Fedora updates instead of a one-off hack.

Status (as of 2026-11-01): builds and runs on one machine (Fedora 44, NVIDIA proprietary driver, GCC 16, Qt 6.11.2).
Image sequences and H.264 / HEVC / ProRes movies play on native Wayland with a libadwaita window frame; a
self-contained rpm (bundled Qt, ~215 MB) can be built locally; startup was shortened by about 2 s (first frame 1.76 s -> ~1.0 s, idle 2.9 s -> ~1.1 s, warm, no media loaded). Verification was
done mostly on private headless compositors; several things are explicitly **not verified** (HiDPI, other
compositors, audio output, other Fedora releases). See [06-open-issues.md](06-open-issues.md). Binaries are not
published.

## Resumen en espanol

Este proyecto porta **OpenRV** (version abierta de RV, licencia Apache-2.0) para que funcione de forma **nativa en
Wayland** en **Fedora 44**, compilado contra el **Qt 6.11.2 del sistema**. Parte de la rama `main` de OpenRV
(commit `cade394`, "4.0.0", VFX CY2026) y anade unos pocos commits (rama `wayland-qt6`) mas scripts, parches y la
receta de un rpm autocontenido en `wayland-fedora/`.

Hitos: se descarto primero reescribir RV en Rust (prototipo `rvr`, en pausa) y se opto por portar OpenRV; viewport
negro en Wayland (corregido), scrub de la linea de tiempo que se cortaba al salir el puntero (corregido), video
H.264/HEVC/ProRes (corregido con FFmpeg propio), aspecto original, icono nuevo, rpm autocontenido en `/opt/openrv`
(~215 MB) y optimizacion del arranque en dos rondas (de ~2,9 s a ~1,06 s hasta estar inactivo en caliente; primer frame de 1,76 s a ~1,0 s).

Estado: probado en una sola maquina (Fedora 44, NVIDIA, GCC 16) y casi todo en compositores privados sin pantalla.
**No verificado**: HiDPI / escalado fraccional, otros compositores (KDE, Sway), salida de audio, otras versiones
de Fedora, GPUs Mesa. Los binarios no se publican (codecs con patentes, Qt/Chromium empaquetado): hay que
compilarlo uno mismo. Los detalles estan en los documentos de abajo (en ingles); el mantenedor puede empezar por
`01-journey.md` y `06-open-issues.md`.

## Reading order

| # | Document | Read it for |
|---|---|---|
| 1 | [01-journey.md](01-journey.md) | What was tried, in order, and why each decision or pivot was made |
| 2 | [02-technical-discoveries.md](02-technical-discoveries.md) | Every bug and finding: symptom, root cause, fix, commit, file |
| 3 | [03-startup-performance.md](03-startup-performance.md) | How startup was measured and shortened; numbers; rounds 1 and 2 |
| 4 | [04-packaging-rpm.md](04-packaging-rpm.md) | How the self-contained rpm is built and what it relies on |
| 5 | [05-testing-and-testbeds.md](05-testing-and-testbeds.md) | How things were verified without touching a real desktop; what was and was not verified |
| 6 | [06-open-issues.md](06-open-issues.md) | Honest backlog, caveats, licence and clean-room note |

Older, more detailed lab notes remain valid and are referenced from the documents above: [`../README.md`](../README.md)
(overview and quick start), [`../BUILD_NOTES.md`](../BUILD_NOTES.md) (the first build, item by item),
[`../MAINTENANCE.md`](../MAINTENANCE.md) (what to do when upstream, Qt, PySide6, GCC or FFmpeg change),
[`../packaging/README.md`](../packaging/README.md) and [`../tools/testbed/README.md`](../tools/testbed/README.md).

## What changed vs upstream

Base: tag `upstream-base-cade394` = upstream `cade394` (2026-10-28). Commits on `wayland-qt6` above it, oldest first
(from `git log --oneline upstream-base-cade394..HEAD`; commits that only add files under `wayland-fedora/` are
grouped at the end).

| Commit | Date | Files (code) | Purpose |
|---|---|---|---|
| `1e9bec3` | 2026-10-29 | `cmake/defaults/CY2026.cmake`, `cmake/dependencies/python3.cmake`, `cmake/dependencies/qt6.cmake`, `src/bin/apps/rv/main.cpp`, `src/build/make_pyside6.py`, `src/build/test_python_distribution.py`, `src/lib/app/RvCommon/{CMakeLists.txt,GLView.cpp,RvDocument.cpp}` | Build against system Qt 6.11.2 / PySide6 6.11.2 / GCC 16; no X11 call on Wayland; desktop OpenGL 4.1 compat format on Wayland (patch 0001) |
| `972e559` | 2026-10-29 | `src/lib/app/RvCommon/GLWindow.cpp` | Black viewport: restore `GL_BACK` draw/read buffer on Wayland (0002) |
| `4dd29f5` | 2026-10-29 | `src/lib/app/RvCommon/GLWindow.cpp` | Timeline scrub keeps going outside the viewport on Wayland (0003) |
| `d675d6f` | 2026-10-29 | `src/lib/app/RvCommon/RvDocument.cpp` | Stop the Qt 6.11 "wildcard disconnect" warning flood (0004) |
| `2290950` | 2026-10-29 | `cmake/dependencies/ffmpeg.cmake`, `cmake/dependencies/patch/ffmpeg_n8.0_av_stream_get_first_dts.patch` | Bundled FFmpeg re-exports a symbol QtWebEngine imports (0005) |
| `ac12806` | 2026-10-29 | `src/lib/app/RvCommon/{CMakeLists.txt,RvApplication.cpp}` | Original gradient QSS on Linux; window size includes the menubar (0006) |
| `fe62385` | 2026-10-29 | `src/lib/app/RvCommon/RvFileDialog.cpp` | No size grip on Wayland in the Open dialog (0007) |
| `b3088f4` | 2026-10-30 | `src/bin/apps/rv/RV.svg`, `src/bin/apps/rv/RV.ico` | New icon (SVG source, regenerated `.ico`) |
| `43cb7f1` | 2026-10-31 | `src/lib/app/py_rvui/rv/runtime.py` | Defer the QtWebEngine user-agent setup (startup) |
| `0495a0f` | 2026-11-01 | `src/lib/app/py_rvui/rv/runtime.py`, `src/plugins/rv-packages/webview2/webview2.py` | Start QtWebEngine lazily, on the first web view (startup) |
| `bd35652` | 2026-11-01 | `src/build/sitecustomize.py` | Locate certifi's CA bundle without importing certifi (startup) |
| `86f93c2` | 2026-11-01 | `src/plugins/rv-packages/otio_reader/otio_reader_plugin.py`, `src/plugins/rv-packages/session_manager/local_thumbnail_gen.py` | Import `opentimelineio` (~175 ms) and `psutil` (~37 ms) on first use (startup) |
| `703e5f4`, `7442787`, `1c52b62`, `0115237`, `d5c6ebb`, `61de07e`, `19e07dd`, `56542cd` | 2026-10-29 / 30 | only under `wayland-fedora/` | README, build notes, patches/, packaging, tools, update script, maintenance checklist |

Patches 0001-0012 in [`../patches/`](../patches) are, in order, `1e9bec3`, `972e559`, `4dd29f5`, `d675d6f`, `2290950`,
`ac12806`, `fe62385`, `b3088f4`, `43cb7f1`, `0495a0f`, `bd35652` and `86f93c2`. `patches/source_patches.diff` is the
combined diff of all of them against `upstream-base-cade394` (without `wayland-fedora/`; it carries no binary data, so
the regenerated `RV.ico` only appears in patch 0008, which is made with `--binary`).
