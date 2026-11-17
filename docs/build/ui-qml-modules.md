# One QML module per widget of src/gui/ui: not adopted

Phase FU5 of the architecture plan asked whether the widgets of `src/gui/ui` should become
static libraries and QML modules of their own (`Telar.Gui.<Path>`) once they are out of the
include cycle. The plan's rule was to adopt that only if build and startup show no regression.

The first widget, `app/overlays/peek`, was split, with the two layers below it that the split
requires. Startup did not change measurably. The build did: with three new modules, the cold
build of the module set took 3.6 s and 4.7 s longer (+5%, +7%) in the two alternated Debug
rounds, with more CPU time and a memory peak 111 and 197 MiB higher, because each module adds
about eleven translation units of its own. So the rule says no, the second step of the
experiment (`palette` with its child `suggestions`) was not run, and `Telar.Gui` stays the one
QML module. The middle option, C++ libraries whose types `Telar.Gui` registers, changed nothing
measurable at startup, built slower in every cold pair by amounts close to the noise, and makes
an edit of a widget rebuild more.

`tools/ui-graph.py HEAD --rules` in CI keeps enforcing the layering, as it does today.

The experiment's code is not for integration: the peek split is `4a2408acf` and `f716b740b` on
`arch/qml-modules`, the middle option `709d784cc` on `arch/qml-modules-foreign`. The numbers are
in the `fu5` entry of `architecture-baseline.json`.

## What was tried

All on top of `4fefd3727` (the target tree of `src/gui/ui`, one CMakeLists.txt per folder).

| Variant | Commit | What |
| --- | --- | --- |
| baseline | `bd2aa8dfc` | `Telar.Gui` as today, with the startup probe of `c052689f4` |
| peek | `f716b740b` (on `4a2408acf`) | `ui/foundation` → `gui-ui-foundation` / `Telar.Gui.Foundation`; `ui/design` → `gui-ui-design` / `Telar.Gui.Design`; `app/overlays/peek` → `gui-ui-peek` / `Telar.Gui.App.Overlays.Peek` |
| middle | `709d784cc` (branch `arch/qml-modules-foreign`) | `ui/foundation` and `app/overlays/peek` as C++ libraries; `Telar.Gui` registers their types with `qt_generate_foreign_qml_types`; every QML file stays in `Telar.Gui` |

Every QML file imports `Telar.Gui`, which holds `app/`, and `app/` shows the peek panel. So the
panel's module cannot import `Telar.Gui`: the layers it uses, `design/` (`CellText`,
`FormTextField`) and `foundation/` (the store its controller reads), had to become modules
first. That requirement is part of the measured cost: the peek variant has three new modules,
not one.

## How it was measured

macOS 26 (Darwin 25.6.0) on arm64, 8 cores, 16 GiB, LLVM 23.1.5, Qt 6.12.0 (shared libraries).
Another agent shared the machine; builds were serialized with it through a lock, but its other
work and the user's editor show in the load averages, which are recorded with each build in the
`fu5` entry of `architecture-baseline.json`.

- **Startup.** `gui-startup-probe` (`src/gui/tools/startup_probe.cpp`) builds the window as the
  GUI tests do: `ApplicationController` with the default configuration and no runtime,
  `QQmlApplicationEngine::loadFromModule("Telar.Gui", "Main")`, `setWindow`, then the first
  `frameSwapped`, on the offscreen platform and the software scene graph.
  `src/gui/tools/measure_startup.py` spawns copies of the probes kept in a folder without a
  `Telar/` directory (an installed GUI has none; a build tree's on-disk `qmldir` files are read
  before the embedded ones), 3 warm-up rounds, then rotating rounds in which every build runs
  once. Times are milliseconds from just before the spawn, so the dynamic loader and the static
  initializers that register the QML types count. *frame* is the first presented frame; *qml* is
  the QML load alone (window created minus controller ready). For a comparison it gives the
  median of the per-round differences with a distribution-free 95% interval of that median.
- **Cold build.** From an empty tree (`out/fu5-cold-<preset>`), timed and memory-sampled the way
  `tools/module-metrics.py` samples the fb4 cold build, in three steps: configure;
  *dependencies*, every library `gui-quick` links outside `ui/` (the same code in every variant,
  so it shows the noise); *QML set*, `telar-gui` and `gui-startup-probe`, which is `gui-quick`,
  every `gui-ui-*` library, their plugins, registrations, caches and resources, and two links.
  CPU time is user plus system of the whole build. The variants alternate: baseline, variant,
  baseline, variant, each in Debug (`dev`) and then Release (`release`).
- **Incremental.** After a build that brought the targets up to date, touch
  `src/gui/ui/app/overlays/peek/peek_controller.cpp` and rebuild, twice. Debug rebuilds every
  executable that links `gui-quick` (39: `telar-gui`, the probes and the GUI tests); Release,
  `telar-gui` and the probe (Release configures no tests). Steps are counted from Ninja's
  output.
- **Module set.** From `build.ninja`: static libraries, plugins, plugin init objects and
  resource object libraries of `gui-quick` and the `gui-ui-*` targets, their qmlcache units and
  batch units, and the size of `telar-gui`.

## Startup

Median milliseconds from the spawn to the first frame, and the median per-round difference with
its 95% interval. Faster: rounds in which the variant was faster than the baseline.

| Build | Rounds | Baseline | Variant | Difference | Interval | Faster |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| Debug, peek | 40 | 384.7 | 384.0 | −0.5 (−0.1%) | −4.8 … +3.9 | 22 |
| Release, peek | 40 | 236.5 | 239.3 | +1.6 (+0.7%) | −0.2 … +4.2 | 14 |
| Release, peek (three-way run) | 60 | 253.0 | 252.4 | +0.9 (+0.3%) | −2.1 … +5.2 | 26 |
| Debug, middle | 40 | 392.4 | 392.4 | −1.8 (−0.5%) | −5.3 … +3.5 | 24 |
| Release, middle | 40 | 246.1 | 244.9 | −0.1 (−0.0%) | −2.1 … +1.6 | 21 |
| Release, middle (three-way run) | 60 | 253.0 | 253.1 | −0.4 (−0.1%) | −2.1 … +3.6 | 32 |

Every interval of the table contains zero: neither variant changes startup by an amount these
runs can resolve. They cannot exclude up to about +2% (+4 to +5 ms) for the peek variant in
Release, where the first run leaned that way (14 of 40 rounds faster) and the second did not.
The QML load alone moved by +0.3 ms (interval −0.7 … +1.2) and +0.8 ms (+0.03 … +5.3) for peek
in Release, the only interval that excludes zero, and by at most 0.6 ms, with intervals that
contain zero, in every other case.

Peak resident memory grew by 0.08 MiB (0.02 … 0.14) with the peek modules and by 0.18 MiB (0.05
… 0.22) with the middle option in Release, out of 115.8 MiB.

Absolute times of a run alone: Debug 383.3 ms to the first frame (quartiles 379.5–385.7), 133.2
ms before `main`; Release 239.2 ms (237.2–242.5), 20.9 ms before `main`. The Release runs
drifted between 236 and 253 ms over the session with the machine's load, which is why only
paired rounds are compared.

## Build

### Cold build of the QML set

Wall time, CPU time and memory peak of the *QML set* step; the *dependencies* step, the same
code in both, as the control.

| Build | Baseline | Peek | Dependencies (baseline / peek) |
| --- | --- | --- | --- |
| Debug, round 1 | 72.9 s, 279.0 s CPU, 2335 MiB | 76.5 s, 283.0 s CPU, 2446 MiB | 29.1 / 28.3 s |
| Debug, round 2 | 70.4 s, 275.0 s CPU, 2367 MiB | 75.1 s, 284.7 s CPU, 2564 MiB | 28.7 / 28.3 s |
| Release, round 1 | 65.0 s, 324.1 s CPU, 2852 MiB | 69.0 s, 335.5 s CPU, 2643 MiB | 29.4 / 29.2 s |
| Release, round 2 | 68.4 s, 338.1 s CPU, 2701 MiB | 69.3 s, 334.6 s CPU, 2645 MiB | 29.7 / 29.2 s |

The same for the middle option, in its own alternated campaign:

| Build | Baseline | Middle | Dependencies (baseline / middle) |
| --- | --- | --- | --- |
| Debug, round 1 | 70.2 s, 275.1 s CPU, 2300 MiB | 72.7 s, 278.5 s CPU, 2419 MiB | 30.9 / 29.0 s |
| Debug, round 2 | 69.1 s, 272.7 s CPU, 2322 MiB | 72.7 s, 281.0 s CPU, 2427 MiB | 27.9 / 28.8 s |
| Release, round 1 | 65.8 s, 324.7 s CPU, 2724 MiB | 67.7 s, 332.0 s CPU, 2780 MiB | 30.6 / 29.0 s |
| Release, round 2 | 63.8 s, 323.4 s CPU, 2827 MiB | 67.3 s, 329.8 s CPU, 2876 MiB | 29.1 / 30.9 s |

In Debug every peek sample is slower than every baseline sample. Round by round the QML set took
+3.6 s and +4.7 s of wall time (+5% and +7%), +4.0 s and +9.7 s of CPU (+1.4% and +3.5%) and
+111 MiB and +197 MiB of peak memory, while the control step moved by less than 1 s. In Release
the rounds give +4.0 s and +0.9 s of wall time, +11.4 s and −3.5 s of CPU and a lower memory
peak (−209 MiB, −56 MiB); the baseline's own two samples differ by 14 s of CPU, so two samples
per variant do not settle Release either way.

The first cold build of the baseline and of peek, before the alternated runs, ran under
different loads (a one-minute load average of 19 against 8.5 in Debug) and is not used; both are
in the JSON (`baseline.cold_build`, `peek.cold_build_unpaired`).

Where the time goes: the three modules add 32 compile units to the Debug QML set (238 → 270) and
34 to the Release one (134 → 168), and Ninja runs 123 and 127 more steps (scans, module
collation, archives, `qmltyperegistrar`, `qmlcachegen`, autogen). Per module, the new units are
the type registration, the plugin class, the plugin's init object, three `*_moc_imports` units
(library, plugin, init) and one to three resource objects with their init units. All of them
parse Qt headers or import the GUI's domain modules, so they are not cheap. Outside Debug the
library's sources also fall into batches of their own: 10 units with 114 sources become 12
(`gui-quick` 6, `gui-ui-foundation` 3, `gui-ui-design` 2, `gui-ui-peek` 1, holding 70, 27, 16
and 1 sources), and a partly filled batch costs about as much as a full one.

The middle option is slower in every pair too, by less: +2.5 s and +3.6 s of wall time in Debug
(+3.6%, +5.2%) with +3.4 s and +8.3 s of CPU, and +1.9 s and +3.5 s in Release (+2.9%, +5.5%)
with +7.3 s and +6.4 s of CPU (+2.2%, +2.0%). In that campaign the control step moved by up to
1.9 s and 7 s of CPU between variants, so these differences are close to the noise: four pairs
in the same direction suggest a cost, they do not size it. Its two libraries add 4 compile units
in Debug and 6 in Release: a foreign registration and a `*_moc_imports` unit each, and in
Release two more batches (12 instead of 10: `gui-quick` 8, `gui-ui-foundation` 3, `gui-ui-peek`
1).

The peek variant's cost is that of three modules. The tree has 20 widget folders under `app/`
with QML of their own, plus `design/` and `foundation/`; converting them all would add on the
order of 200 more units of this kind, about as many as the Debug QML set compiles today. That is
an extrapolation from the three measured modules, not a measurement.

### Incremental: touching the peek controller

| Build | Baseline | Peek | Middle |
| --- | --- | --- | --- |
| Debug, 39 executables | 12.2 s, 12.8 s: 1 compile, 1 archive, 39 links | 11.2 s, 10.2 s: 1 compile, 1 archive, 39 links | 14.2 s, 14.0 s: 3 compiles, 2 archives, 39 links |
| Release, `telar-gui` and the probe | 5.0 s, 3.6 s: 1 batch of 12 sources, 1 archive, 2 links | 2.6 s, 1.7 s: 1 batch of 1 source, 1 archive, 2 links | 4.9 s, 4.4 s: 3 compiles, 2 archives, 2 links |

A widget library relinks exactly what `gui-quick` relinks: every executable that links
`gui-quick` links its children too, so the 39 Debug relinks stay 39. The peek variant only saves
the compile of the other 11 sources of the touched batch in Release, and the archive of the
large `libgui-quick.a` (470 MB in Debug) for a 7.7 MB one; the Debug times moved within the
spread of the machine's load (6.6 to 14.3 one-minute load average during these builds).

In the middle option a change to the library regenerates the foreign registration:
`qt_generate_foreign_qml_types` makes the generated files depend on the library target itself,
so every rebuild of the library rewrites them and `gui-quick` compiles the generated unit and
its own type registration again and archives `libgui-quick.a`.

## Size

| | Baseline | Peek | Middle |
| --- | ---: | ---: | ---: |
| Static libraries of the set | 2 | 8 | 4 |
| QML plugins | 1 | 4 | 1 |
| Plugin init objects | 1 | 4 | 1 |
| Resource objects | 8 | 14 | 8 |
| qmlcache units | 94 | 94 | 94 |
| Release batch units | 10 | 12 | 12 |
| `telar-gui`, Release | 22 365 688 B | 22 383 000 B (+17 312) | 22 366 920 B (+1 232) |
| `telar-gui`, Debug | 67 479 896 B | 67 528 424 B (+48 528) | 67 494 056 B (+14 160) |

The resource objects of a module are its `qmldir` (always), its QML files (when it has any) and
the extra `qmldir` files of QTP0004 (when its QML files sit in subfolders):
`Telar.Gui.Foundation` 1, `Telar.Gui.Design` 3, `Telar.Gui.App.Overlays.Peek` 2.

## What the split forces on the rest of the code

Peek variant (`4a2408acf`, `f716b740b`):

- The layers below the widget become modules before the widget can: two more libraries and
  modules than the widget itself.
- `src/gui/CMakeLists.txt` gains two helpers, `telar_gui_ui_library` and `telar_gui_ui_module`,
  that start and end such a library, and the batching and moc-scan functions move above
  `add_subdirectory(ui)` so the folders can call them; batching takes `ui/` from the process's
  folder instead of the current one.
- `gui-quick`'s precompiled Qt headers move to `gui-ui-foundation`, the lowest library, and
  `gui-quick` and the others reuse them (`REUSE_FROM`); a library above `gui-quick` could not be
  the donor without a dependency cycle.
- The two `platform/` sources that `ui/foundation` calls (`runtime_endpoint`, `login_shell`) and
  the compile-time link host header move to `gui-ui-foundation`.
- `ui/foundation/input` must put itself on the include path: the generated registration includes
  each registered header by bare name inside `__has_include`, and `window_actions.hpp` had been
  found only through another header of `gui-quick`. In its own module the include silently
  vanished and the registration failed to compile.
- The 26 QML files of `design/` import `Telar.Gui.Design` instead of `Telar.Gui`; an import of
  `Telar.Gui` from below would be a cycle. `PeekPanel.qml` imports `Telar.Gui.Design`, and
  `CommandDialog.qml`, which shows it, imports the peek module.
- `Telar.Gui` imports `Telar.Gui.Foundation` and `Telar.Gui.Design` in its `qmldir` (`IMPORTS`),
  so the other 65 QML files of `app/` keep `import Telar.Gui` unchanged. A full conversion would
  replace that line in every widget's files with the modules it uses.
- `gui-quick` links each module's library and plugin publicly, so the 39 executables that link
  `gui-quick` and `gui-quickplugin` needed no change.
- `tests/qml_fixture.hpp`: `createChrome` gains an overload that takes the module; the two calls
  that load `PeekPanel` in `machine_window_test.cpp` pass `Telar.Gui.App.Overlays.Peek`. Loading
  `ChromeIcon`, `FormTextField`, `ChromeText` and `ApplicationMark` by name from `Telar.Gui`
  still works through the `qmldir` imports, and so do the inline components that import
  `Telar.Gui`.
- QML type registration: each module registers its own types (`Store` and `WindowActions` in
  `Telar.Gui.Foundation`, the design controls in `Telar.Gui.Design`, `PeekController` in the
  peek module). `Telar.Gui`'s properties of those types needed no change, and the type tools
  printed the same three warnings as before and no new one.

The 32 GUI tests whose executables the incremental build relinks (among them `gui-quick`, which
loads `Main` against a runtime, and `gui-machine-window`, which loads `Main` and `PeekPanel`)
and `gui-startup-tools` passed offscreen in Debug on `f716b740b`. `tools/ui-graph.py HEAD
--rules` and `tools/check-cpp-modules.py` pass on it.

## The middle option

Per-widget C++ static libraries whose QML-registered types `Telar.Gui` registers with
`qt_generate_foreign_qml_types`, all QML files staying in `Telar.Gui` (`709d784cc`, for
`ui/foundation` and `peek`). It needs no import, test or fixture change. It does need:

- the foreign registration generated from `gui-quick`'s folder, since a custom command's output
  only reaches the targets of the folder that declares it;
- `gui-quick`'s build folder on its include path, because the generated registration includes
  the generated headers by bare name, and every folder whose types it registers on `gui-quick`'s
  include path too;
- a `gui-quick` that registers the types of every library below it, so the registration still
  lives in one place.

`gui-machine-window` and `gui-quick` passed on it.

What it would buy compared with today: a C++ target per folder, which a test or a tool could
link without the rest of `gui-quick`; none does today. It does not enforce the layering, since
`gui-core` exports `src/gui` as a public include directory (`src/gui/CMakeLists.txt`) and any
target can include any header of `ui/`; the CI gate does that already. It does not save relinks
while every binary links `gui-quick`. What it costs: a cold build slower in every pair (+1.9 to
+3.6 s, close to the noise), the incremental rebuild above (3 compiles and 2 archives instead of
1 and 1), one more static library per folder, the Release batches split per library as with
modules (12 units instead of 10), +0.16 to +0.18 MiB of peak memory at startup and +1 232 B of
`telar-gui`. Startup time does not change measurably.

## Decision

Not adopted: `Telar.Gui` stays one QML module and the folders of `ui/` keep adding their files
to `gui-quick` (U11 stays as it is). The peek split regressed the Debug cold build in every
sample, so the second step (palette and suggestions) was not run, as the experiment required.
The middle option is not adopted either: it changes nothing measurable at startup, buys no
enforcement or relink that the tree lacks, and makes an edit of a widget rebuild more; its cold
build leaned slower in every pair.

The probe and the measuring script stay: they are the startup tool the plan lacked.

## When to revisit

- Qt makes a module cheaper: no plugin, init object and `moc_imports` units per module for
  static backing libraries, or registration of several modules in one unit.
- `qt_generate_foreign_qml_types` depends on the library's metatypes file rather than on the
  library, so an edit of a widget no longer rebuilds `Telar.Gui`'s registration; the middle
  option's incremental cost would then need measuring again.
- `gui-core` stops exporting `src/gui` publicly, so that a target per folder would enforce the
  layering by itself; that would be something the targets buy that the CI gate does not already
  give.
- Release edits of a widget become a bottleneck: the one gain measured here, compiling the
  touched widget without its batch, comes from the batching, and batching per folder of
  `gui-quick` would give it without new targets. That was not measured.
- A measurement on an idle machine shows the Release cold build or startup differences settle
  differently; the Release numbers above do not decide either way.
