# Pick list

A configured pick opens the palette on a list of options. The person chooses
one and Telar runs the pick's `on_select` command with it, then reruns the bar
sources so they show what the command changed. The client owns all of it:
the runtime never sees a pick.

## End-to-end path

```text
config.lua client.picks, telar.action.pick("name")
          |
Generation.parsePicks / parsePick / parseAction("pick")
          |
BarConfiguration.picks (PickDefinition) + Action.pick = index
          |
bar component click or key binding
          |
actions.executeAction -> pick_list.open
          |                          |
name_prompt.openNamePrompt(.pick)    model.pick_list.begin
          |                          |
          |      list command? -> to_background (pick_command, .list)
          |                          |
          |      job_runner -> command.runFor(.lines) -> Message.pick_command
          |                          |
          |      pick_list.finish -> fill: readLines or Generation.invokePick
          |                          |
          +---- CommandPalette draws model.pick_list through pick_list.collect
          |
Enter -> name_prompt.finishPromptList -> pick_list.choose
          |
PickDefinition.selection(value) -> to_background (pick_command, .select)
          |
job_runner -> command.runFor(.ignored) -> pick_list.finish
          |
failure: client_diagnostic.replace    success: bar_updates.refreshSources
```

## Options

A pick lists its options in one of three ways, all checked when the
configuration loads; an `items` function without a command is rejected:

- `items` as a list: parsed once at load, so a bad option fails the reload;
  kept as a Lua value and parsed again on each opening.
- `command` alone: each nonempty line of its output, trimmed, is one option
  (`pick_list.readLines`). The value is the line as printed, tabs included;
  the label shows tabs as spaces and is cut at a character boundary.
- `command` and an `items` function: the function receives the render
  context with `ctx.output` and returns the list.

`PickItems` holds at most 4096 options and 256 KiB of text. A label and a
detail are at most 128 bytes, a value 512, all printable UTF-8 on one line;
a value may also hold tabs. `PickItems.keep` keeps what fits: a longer label
or detail is cut at a character, an option whose value is longer is left out
(a value is one argv element and is never cut), and options past the count or
the text are left out. `PickItems.reaches` names each limit passed and the
pick flow reports them, so the palette shows the options that fit and the
notice says which limit to raise. An invalid option still fails the list.

## Commands

Both commands are `BarCommand` values: at most 32 arguments and 4096 bytes,
run without a shell by the background job runner, never on the event loop.
`timeout_ms` (100 to 60000, default 2000) bounds each whole run, from spawn
to exit (`command.runFor`): the deadline is absolute, so output that trickles
in cannot extend it, and the wait for the exit is bounded too. Each command
runs in its own process group. One that passes its deadline gets TERM to the
group, KILL 200 ms later, and a bounded wait after that; a process that
survives even KILL is left unreaped rather than blocking the worker. One that
exits in time keeps its group, so a helper may leave background work
running. The same runner serves bar and panel commands.

The list command's output is bounded to 256 KiB (`OutputUse.options`), room
for `pi --list-models`, which prints about 43 KiB; past it the command keeps
its first whole lines and reports `picks.max_pick_output_bytes`. `on_select` output and
errors go to `/dev/null`; only the exit status counts.

`on_select` must hold an argument that is exactly `{}` after the program.
`PickDefinition.selection` replaces each such argument with the chosen value
and nothing else: the value is always one argv element, never text inside
another argument, and never the program. A helper that passes it to a shell
must use it as a positional parameter (`"$1"`), not paste it into the script.

## Identity and staleness

`PickListState` keeps two execution ids. `listing` names the list command the
open list waits for; closing the palette, opening any other prompt
(`name_prompt.openNamePrompt`) or another pick clears it, and a completion
first checks with `PickListState.shownBy` that the palette on screen is still
the opening that started it, so a late completion is released and dropped
without running Lua. `selecting` names a running
`on_select`; it outlives the palette and keeps its own pick index and
configuration generation. A second choice while one runs is refused with a
diagnostic rather than queued.

A configuration reload changes the generation. A list completion or a choice
whose generation no longer matches fails or does nothing; a finished
`on_select` from an older generation still reports its failure but refreshes
nothing.

## Refresh

With `refresh` (the default), a successful `on_select` calls
`bar_updates.refreshSources`: every scheduled bar source and the open panel
become due now. A bar command already running records one pending rerun, so a
refresh never runs two copies of the same source.

## Proof

`PickItems`, `PickDefinition`, `PickListState` and `pick_list` unit tests
cover bounds, tabs, argument replacement and matching. `command.zig` tests
cover a command that keeps printing past its deadline, one that ignores TERM
with a grandchild, ignored output and failed exits. The client integration
tests in `src/client_tests/pick_list.zig` open picks with written options,
with a command, with a failing, a slow and an oversized command, replace the
palette mid-list, reload with a command running, refuse a second choice,
skip the refresh when asked, pass a value that starts with `-`, reject one
that overflows the argv, and check that `on_select` receives the choice as
one argument and that the bar reruns.
`tools/gui_pick.py` runs the Pi example of `docs/configuration.md` verbatim in
the native window against an isolated runtime and home, clicks the bar, types
and chooses, and checks the settings file and the refreshed bar.
