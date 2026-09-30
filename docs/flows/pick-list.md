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
configuration loads:

- `items` as a list: parsed once at load, so a bad option fails the reload;
  kept as a Lua value and parsed again on each opening.
- `command` alone: each nonempty line of its output, trimmed, is one option.
- `command` and an `items` function: the function receives the render
  context with `ctx.output` and returns the list.

`PickItems` holds at most 1024 options and 64 KiB of text. A label and a
detail are at most 128 bytes, a value 512, all printable UTF-8 on one line. A
list that breaks any bound fails as a whole and the palette says why; it is
never cut short, because a missing option is worse than a visible error.

## Commands

Both commands are `BarCommand` values: at most 32 arguments and 4096 bytes,
run without a shell by the background job runner, never on the event loop.
`timeout_ms` (100 to 10000, default 2000) bounds each of them. The list
command's output is bounded like a render command's, 64 KiB of text.
`on_select` output is read up to the same bound and discarded; only the exit
status counts.

`on_select` must hold an argument that is exactly `{}` after the program.
`PickDefinition.selection` replaces each such argument with the chosen value
and nothing else: the value is always one argv element, never text inside
another argument, and never the program. A helper that passes it to a shell
must use it as a positional parameter (`"$1"`), not paste it into the script.

## Identity and staleness

`PickListState` keeps two execution ids. `listing` names the list command the
open list waits for; closing the palette or opening another pick clears it,
so a late completion is released and dropped. `selecting` names a running
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
cover bounds, argument replacement and matching. `command.zig` tests cover
ignored output and failed exits. The client integration tests in
`src/client_tests/configuration.zig` open picks with written options, with a
command, with a failing, a slow and an oversized command, and check that
`on_select` receives the choice as one argument and that the bar reruns.
`tools/gui_pick.py` runs the Pi example of `docs/configuration.md` verbatim in
the native window against an isolated runtime and home, clicks the bar, types
and chooses, and checks the settings file and the refreshed bar.
