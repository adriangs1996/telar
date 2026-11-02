# Development configuration

`just app` and `just run` select `dev/config.lua` through
`TELAR_DEVELOPMENT_CONFIG`. The runtime socket and history stay under `.dev/`.
An already-running development runtime keeps its original configuration selection;
stop it with `just stop` before testing a different configuration. This stops its
panes too. Production uses a different socket and is not stopped.

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
