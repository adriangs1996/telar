The window CLI port is implemented in `window.cpp` and `window_options.hpp`.
It queries an exact client generation, forwards the existing `ClientCommand`,
checks the correlated completion and preserves its action, status and text.
It never imports GUI/runtime service code or invokes Zig.

The reference grammar is `src/cli/arguments/RoutedOptions.zig:14`,
`ClientOptions.zig:12`, `SuggestionOptions.zig:13`,
`NotificationOptions.zig:15` and `ConfigCheckOptions.zig:8` in that directory.
Execution and output follow `src/cli/routed.zig:25`, `PluginQuery.zig:10`,
`client_control.zig:21`, `suggestion.zig:20`, `notification.zig:23` and
`config.zig:79`. Numeric arguments retain Zig's unsigned decimal syntax,
including interior underscores and rejection of signs. JSON strings use
`JsonEscapes::standard`; parsed configuration/plugin JSON is re-encoded,
including Zig's decimal float formatting.

[Recorded results](measurements/window-port.json) retain binary hashes, exact
mismatches and all startup samples. On this Mac:

- `check_window_cli.py`: **255/262** comparisons match. Validation **93/93**,
  wire fixtures and the real 30-second receive deadline **106/106**,
  Lua configuration **12/13**, real attached GUI **39/45**, and real runtime
  without a window **5/5**. Only numeric client identities/generations are
  normalized; all other stdout/stderr bytes and exit codes are retained.
- A supplementary comparison of a 600-byte UTF-8 notification body cut to
  512 bytes matches stdout, stderr, exit status and the `ReportLimit` frame.
  That case is now included in the comparison script and permanent test.
- `cli-window-tests`: **116** cases without Zig. These include argument errors,
  exact output, malformed/stale completions, paginated plugins, suggestion
  states, notification validation, canonical JSON numbers and config compilation.
- Runtime CTest: **39/39**. Its descriptor-inheritance test requires a
  process-local `ulimit -n 8192`; the initial run with the lower inherited limit
  failed at `services/runtime-cpp/tests/platform_test.cpp:165`, and the isolated
  repeat passed. CLI-only configure/build and CTest: **5/5**.
- Seven alternating startup pairs for one `hook claude` event give p50
  **5.341 ms before / 5.204 ms after**, median paired ratio **0.9915**.
  This is startup/mapping/fixture IPC on this laptop, not GUI/runtime throughput.
  The CLI still links only OpenSSL and system C/C++ libraries.

The seven mismatches are left visible. The CLI does not translate a GUI error
or synthesize a completion to hide them:

| Command/action | Observed difference |
| --- | --- |
| `config check` | The shared C++ Lua validators report `visible must be a boolean`; Zig includes `config.client.sidebar.visible`. Both reject the invalid file and return `InvalidConfig`. Nested validator and registry diagnostic parity remains incomplete. |
| `layout_apply` | A valid exported layout applies on both stacks. For `invalid`, Zig reports `InvalidLength`; C++ GUI reports `Invalid hexadecimal layout token length`. |
| `plugin_enable`, `plugin_disable`, `plugin_run` | Zig retains the plugin name/path in the admitted result's `text`; C++ GUI clears it. Both enable/disable overrides were read back after an adopted configuration generation. The worker fixture action is a no-op. |
| `client_open_history` | With another prompt/copy mode active, Zig refuses `ClientPromptUnavailable`; C++ GUI admits history. Fresh history opening matches. |
| `client_copy_mode` | With history open, Zig refuses `CopyModeUnavailable`; C++ GUI applies copy mode. Entering it in a fresh terminal matches. |

The GUI completion clears `text` at
`services/gui-cpp/application/session.hpp:3525`; its host dispatch is
`services/gui-cpp/qt/application.cpp:825`. Zig starts with a copy of the command
at `src/client/connection/cli_control.zig:32` and checks prompt admission at
`:278`. These are GUI differences; this branch changes no GUI sources or Qt
build. No missing runtime action was found in this package.

`client clipboard copy` and successful host opening by `client open-link` remain
**unverified** end to end. Their CLI wire/output cases match and invalid URI
rejection matches the real GUIs. The comparison does not change the desktop
clipboard or launch a browser/editor. The C++ GUI uses Qt offscreen during the
stack check; the Zig GUI uses its native macOS host. Shared sidebar columns are
kept below both hosts' geometry clamps. Notifications are owned fixtures; the
first notification id is defined as 1 in both fresh notification centers, and
successful dismissal plus repeated dismissal are compared.

`config check` execs the sibling **`telar-config-check`**, preserving its process
identity. The companion uses `dlls/telar-config`, the sandboxed Lua VM and package
registry, checks configured plugin actions and keymap conflicts, reports limits
and retired keys, and writes no configuration. Its separate link keeps Lua and
libghostty's icon-width validation out of hooks. `cmake/window.cmake` builds and
installs it beside `telar`; one include in `CMakeLists.txt` wires in that file.
Standalone CLI builds now need `GHOSTTY_VT_ROOT`. The bootstrap is owned by
`services/cli-cpp/config/bootstrap.lua`; it was copied byte-for-byte from the
reference and creates no new dependency on `src/`.

`window_json.hpp` is a reusable JSON-output helper; `window_options.hpp` owns
this package's argument cursor and unsigned parsing. They are CLI-local, not
imports from another service. No other package's dispatch cases or parity rows
were changed.

To reproduce (use private HOME/XDG/TMPDIR directories and unset inherited
`TELAR_*`; the script isolates its own subprocesses):

```sh
python3 -B services/cli-cpp/tools/check_window_cli.py \
  --zig /path/to/zig-telar --cpp /path/to/cpp/telar \
  --cpp-gui /path/to/telar-gui --scratch /short/private/path \
  --output /short/private/path/results.json --timeouts
python3 -B services/cli-cpp/tools/measure_window_hook.py \
  --baseline /path/to/telar-before --candidate /path/to/telar-after \
  --scratch /short/private/timing --output /short/private/timing/results.json
```

The Zig oracle was built from this worktree at the base revision using the pinned
0.16 compiler. Its unmodified libc++ build fails on the installed macOS SDK
because `INFINITY` is undeclared. Only a private copy of the toolchain was
adjusted: `lib/libcxx/include/__random/clamp_to_integral.h` uses
`__builtin_huge_val()` for that reference. Telar's Zig sources were unchanged.
Cargo used the existing Rust toolchain with its cache in the private scratch
area. All builds used `nice -n 10` and at most four jobs. All test runtimes were
stopped; generated `zig-pkg` was moved out of the checkout into scratch. Nothing
was installed, merged or pushed.
