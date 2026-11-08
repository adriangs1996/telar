# Development configuration

`just app`, `just app-release` and `just run` select `dev/config.lua` through
`TELAR_DEVELOPMENT_CONFIG`.

| Command | GUI/runtime build | Socket and history |
| --- | --- | --- |
| `just app` | Debug, `src/*/out/` | `.dev/runtime.sock`, `.dev/history.db` |
| `just app-release` | Release, `src/*/out-dev-release/` | `.dev/release/runtime.sock`, `.dev/release/history.db` |

Release uses the same CMake build type as production packaging, without installing
or replacing an app. Its CLI helpers live in `.dev/release/bin/`, separate from
Debug's `.dev/bin/`. Both modes reuse the managed Qt cache. Debug, Release and
production runtimes can run concurrently.

`just stop` stops only the Debug development runtime. `just stop-release` stops
only the Release development runtime, including its panes. Neither stops production.

An already-running development runtime keeps its original configuration selection;
stop it with the corresponding command before testing a different configuration.
This stops its panes too. Rebuilding a binary does not replace a running runtime;
restart only that development runtime when testing runtime code changes.

The configuration includes terminal appearance, keybindings, clock, host metrics,
GPU history, provider usage panels and read-only Pi defaults. `bar.py` uses only
Python's standard library. It reads optional Claude/Codex usage caches under
`$XDG_CACHE_HOME/telar/bar` or `~/.cache/telar/bar` and selected Pi defaults from
`~/.pi/agent/settings.json`. It does not read credentials, refresh usage caches or
write personal settings. Missing providers stay hidden.

GPU sampling uses macOS IOAccelerator statistics. Other systems show `GPU N/A`.
The displayed theme name is the development theme, not a system theme manager.
Personal theme automation and Pi-setting commands are deliberately excluded.
The development configuration disables proxy interception.

To exercise every bar widget without provider caches or Pi settings:

```sh
TELAR_DEV_BAR_DEMO=1 just app
```

This explicitly selects synthetic GPU, quota and Pi values, including a full
session quota beside a second quota, to check meter spacing. Omit the variable
for live local data. Demo mode does not read provider files.
