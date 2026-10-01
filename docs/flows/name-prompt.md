# Name prompt

The name prompt is bounded, disposable client state shared by workspace
creation, workspace rename and tab rename. `ClientModel.name_prompt` is its
only authority. It owns the target identity, edit field, bracketed-paste state
and `prompt` revision.

The prompt runs on the interactive path. Its field holds at most
`name_prompt.max_field_bytes` (512, the suggestion request bound), and each
target stops at the bound of what it submits (`name_prompt.limit`): a tab
label at `core.max_tab_label_bytes`, a copy-mode search at
`core.max_search_needle_bytes`, a path query at `core.max_path_query_bytes`,
a history query at `OwnedHistoryQuery.max_query_bytes`, a machine label or
SSH destination at its profile bound. A keystroke, paste or initial name
that passes the bound keeps its start that fits, cut at a character, and the
client reports the limit (`prompt.*_bytes`) with the limit notice; renaming
a workspace whose name passes the field opens with the start that fits.
Editing allocates nothing and no borrowed text survives the synchronous
submit effect.

Workspace creation is a two-field form (`Prompt.mode.create_workspace` holds
a `WorkspaceForm`): the name and a working directory bounded by
`core.max_cwd_bytes`. `Tab` moves from the name to the directory and, in
the directory, accepts the selected completion; `Shift+Tab` moves back;
`Up`/`Down` choose a completion; `Enter` creates; `Esc` cancels. An empty
name defaults to the directory's basename. The directory is expanded in the
client (`~`, `$VAR`, `${VAR}`, relative paths against the focused pane's cwd
from `completion/path_expansion.zig`).

### Directory completion

```text
directory edit -> name_prompt.inputPrompt
        |
prompt_paths.refreshPathCompletion (expand, compare with the wanted query)
        |
client.to_background (.path_completion job, observation path)
        |
completion/path_completion.run: one listing, <= 64 directories, <= 4096 B per path
        |
client.Message.path_completion -> Client.update -> completePathCompletion
        |
ClientModel.path_completion (PathCompletionState, Version.path_completion)
```

One listing runs at a time. Every keystroke replaces the wanted query; a
listing that completes for a superseded query is discarded and the wanted one
starts, so a burst of typing costs at most one stale listing. Results are
identified by execution id, never by pointer, and the worker's heap result is
released by the completion operation. Closing the form clears the list.

### Missing directories

Submit performs one `stat` on the expanded path. A missing directory blocks
the submission and sets `WorkspaceForm.confirm_create`; the renderers show
the confirmation instead of the hints, and the next `Enter` sends
`create_workspace` with `create_cwd = true`. The runtime creates the path
(`launch_cwd.createLaunchDirectory`) before proposing the workspace and
refuses relative paths or an existing non-directory. Any edit clears the
confirmation. The window paints the form as a modal with the list
(`WorkspaceForm`).

## Opening and input

```text
native action or tab-bar intent
        |
name_prompt.openNamePrompt
        |
NamePromptState.begin
        |
ClientModel.name_prompt.version() (Version.prompt)

window key, text or paste event
        |
GuiAdapter.drainInput -> GuiAdapter.widgetInput
        |                                     |
  not consumed                      prompt text field owns it
        |                                     |
GuiAdapter.routeKey / paste_routing    widget routing editor
        |                                     |
key_routing.routeKeyInput or             semantic Command
paste_routing selects the prompt              |
        |                                     |
        +------------------+------------------+
                           |
       name_prompt.inputPrompt(Input) -> NamePromptState.apply
```

`name_prompt.openNamePrompt` owns opening eligibility and canonical initialization.
It rejects every intent while copy mode or a pane paste owns input, resolves
the current workspace or requested tab and copies its canonical name into the
bounded field. Workspace creation also requires no pending request and an
attached focused pane that can supply the launch directory. Native and tab-bar
input call these concrete opening functions; the functions read request state
and mutate the prompt through the model.

`ClientModel` owns prompt, copy-mode and pane-paste authority. For streamed
paste, `paste_routing` snapshots those modes plus the attachment modal and
`paste_routing` selects one owner. A paste that starts in the prompt
records `Prompt.pasting`; its later chunks and closing boundary stay with that
editor. For keys the prompt's widget did not consume, `key_routing.routeKeyInput`
selects prompt authority
before copy mode or pane input. `key_routing.captures` bypasses configured bindings
while the prompt is active. Mouse input and configured actions are suppressed
in that interval. `pointer_routing.apply` receives no pointer authority, while
`actions.executeAction` returns before selecting a native, Lua or plugin effect.
See [Key routing](key-routing.md).

The window's prompt field translates key, text and paste events into semantic
editor commands; the headless client sends its keys through key routing. The
state component handles grapheme-aware editing and records a revision only for a
visible change. Bracketed-paste start and end change routing without requesting
a frame. A newline inside a paste becomes a space; Enter outside a paste
submits only a non-empty value.

## Submission boundary

```text
NamePromptState.apply(.submit)
        |
borrowed Submission(target, name)
        |
name_prompt.inputPrompt
        |
name_prompt.submitPrompt
        |
create_workspace, rename_workspace or rename_tab request use case
        |
model.to_runtime copies the name
        |
accepted -> NamePromptState.finish
```

The operation keeps the prompt alive while the synchronous effect
uses its borrowed text. It closes the exact prompt only after the selected
request use case accepts the operation. A gate returning `false` leaves the
prompt open. A `model.to_runtime` or transport error also leaves it open and propagates
the error after request correlation has been rolled back.

The prompt does not apply canonical workspace or tab names. Those values still
change only when the runtime response reaches the existing confirmation and
reconciliation use cases.

## Presentation

Neither input routing nor the prompt use case requests a draw. After each
turn of client events, `GuiAdapter.update` observes `ClientModel.version()`
through `Client.presentation.observe`. A changed `prompt` revision asks for a
frame, which folds the latest state.

The window's overlays (`NamePrompt`, `WorkspaceForm`) read the prompt from the
captured `client.Projection`. They render the field and cursor but store no
prompt target, text or paste state and make no lifecycle decision. Multiple
edits before a frame replace obsolete visual work with the latest model state.

## Validation

- `src/model/state/name_prompt.zig` proves bounded editing, revisions,
  cancellation and exact-target completion.
- `src/client/input/name_prompt.zig` owns effect ordering (`inputPrompt`,
  `submitPrompt`); `src/client_tests/renaming_and_telemetry.zig`,
  `input_operations.zig` and `workspace_lifecycle.zig` prove prompt retention
  after blocked or failed submissions.
- `src/client/input/name_prompt_opening.zig` holds input authority,
  workspace-creation gating, target resolution and canonical text.
- `src/client/input/name_prompts.zig` maps semantic host events to commands.
- `src/client/input/paste_routing.zig` wires exclusive prompt or pane
  ownership and ignores unowned phases; `src/client_tests/input.zig` proves it
  through streamed paste.
- `src/client_tests/renaming_and_telemetry.zig` proves request ownership,
  `model.to_runtime` failure recovery and presentation-only frame scheduling
  through the real client.
- `src/gui/tests/overlays.zig`, `navigation.zig` and `widget_interaction.zig`
  prove the window's prompt rendering, pasted text that never reaches the
  child, and preedit ownership.
