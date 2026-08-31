# Name prompt

The name prompt is bounded, disposable client state shared by workspace
creation, workspace rename and tab rename. `ClientModel.name_prompt` is its
only authority. It owns the target identity, edit field, bracketed-paste state
and `prompt` revision.

The prompt runs on the interactive path. Its field holds at most
`schema.max_tab_label_bytes`, editing allocates nothing and no borrowed text
survives the synchronous submit effect.

## Opening and input

```text
native action or tab-bar intent
        |
name_prompts.begin*
        |
OpenNamePromptHandler
        |
name_prompt.State.begin
        |
ClientModel.Version.prompt

host key input                     streamed paste phase
        |                                  |
key_routing adapter                 paste_routing adapter
        |                                  |
KeyRoutingHandler -> prompt    PasteRoutingHandler -> prompt owner
        |                                  |
name_prompts.handleInput                    |
        |                                  |
        +----------------+-----------------+
                         |
                     term.parse
        |
semantic Command
        |
NamePromptHandler.execute -> name_prompt.State.apply
```

`OpenNamePromptHandler` owns opening eligibility and canonical initialization.
It rejects every intent while copy mode or a pane paste owns input, resolves
the current workspace or requested tab and copies its canonical name into the
bounded field. Workspace creation also requires no pending request and an
attached focused pane that can supply the launch directory. The adapter only
translates native or tab-bar intent and reports whether a request is pending.

`ClientModel` owns prompt, copy-mode and pane-paste authority. For streamed
paste, `paste_routing` snapshots those modes plus the attachment modal and
`PasteRoutingHandler` selects one owner. A paste that starts in the prompt
records `Prompt.pasting`; its later chunks and closing boundary stay with that
editor. For normal host keys, `KeyRoutingHandler` selects prompt authority
before copy mode or pane input. `capturesKeys` bypasses configured bindings
while the prompt is active. Mouse input and configured actions are suppressed
in that interval. `PointerRoutingHandler` receives no pointer authority, while
`ActionRoutingHandler` returns before selecting a native, Lua or plugin effect.
See [Key routing](key-routing.md).

The terminal adapter translates bytes into semantic editor commands. The state
component handles grapheme-aware editing and records a revision only for a
visible change. Bracketed-paste start and end change routing without requesting
a frame. A newline inside a paste becomes a space; Enter outside a paste
submits only a non-empty value.

## Submission boundary

```text
name_prompt.State.apply(.submit)
        |
borrowed Submission(target, name)
        |
NamePromptHandler
        |
name_prompts submit effect
        |
create_workspace, rename_workspace or rename_tab request use case
        |
bounded outbox copies the name
        |
accepted -> name_prompt.State.finish
```

The application handler keeps the prompt alive while the synchronous effect
uses its borrowed text. It closes the exact prompt only after the selected
request use case accepts the operation. A gate returning `false` leaves the
prompt open. An outbox or transport error also leaves it open and propagates
the error after request correlation has been rolled back.

The prompt does not apply canonical workspace or tab names. Those values still
change only when the runtime response reaches the existing confirmation and
reconciliation use cases.

## Presentation

Neither input routing nor the prompt use case requests a draw. After each
client event, `client_events` publishes `ClientModel.Version` to `Presenter`.
`Presenter` compares the observed `prompt` revision with its last presented
version and folds the latest state into the paced frame.

`View` receives a borrowed prompt in `RenderInput`. It renders the field and
cursor but stores no prompt target, text or paste state and makes no lifecycle
decision. Multiple edits before a frame replace obsolete visual work with the
latest model state.

## Proof

- `src/frontend/client/name_prompt.zig` proves bounded editing, revisions,
  cancellation and exact-target completion.
- `src/frontend/client/application/name_prompt.zig` proves effect ordering and
  prompt retention after blocked or failed submissions.
- `src/frontend/client/application/name_prompt_opening.zig` proves input
  authority, workspace-creation gating, target resolution and canonical text.
- `src/frontend/client/name_prompts.zig` proves terminal parsing, bracketed
  paste handling and the zero-length incomplete-sequence regression.
- `src/frontend/client/application/paste_routing.zig` proves exclusive prompt
  or pane ownership and ignored unowned phases.
- `src/frontend/client/client_test.zig` proves request ownership, outbox
  failure recovery and presenter-only frame scheduling through the real client
  adapters.
- `src/frontend/client/view.zig` and `src/frontend/client/presenter.zig` prove
  that presentation receives model state without becoming its owner.
