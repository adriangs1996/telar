# Key routing

The native host router produces either a semantic key or a borrowed byte
slice. A key press is assigned to one owner: an attachment modal, the name
prompt, copy mode or the focused pane. Repeat and release retain that owner.
The decision happens
before editor parsing, copy movement, child encoding or media scheduling.

This is client-owned interactive-path policy. `KeyRoutingHandler` uses fixed
values and retains no command or authority snapshot. A prompt key uses a
32-byte stack buffer. Raw bytes come from the router's bounded 4 KiB output,
and `PaneInputHandler` enforces its 8 KiB command limit before enqueueing.

## End-to-end path

```text
host TTY bytes
      |
keybind.Router
      |
semantic key or replayed bytes
      |
InputHandler.key / forward
      |
key_routing adapter
      |
KeyRoutingHandler + authority snapshot + physical lease
      |
      +----------------+----------------+----------------+
      |                |                |                |
attachment modal   name prompt       copy mode        exact pane
      |                |                |                |
optional close    neutral encoding   CopyModeHandler  PaneInputHandler
                                                        |
                                              confirmed Ctrl+V delivery
                                                        |
                                            clipboard preview start
```

`InputHandler` implements the generic callback protocol expected by
`keybind.Router`. It delegates each value. It does not inspect client owners,
encode prompt keys, invoke copy mode, send pane input or recognize `Ctrl+V`.

The adapter takes one synchronous authority snapshot from `View` and
`ClientModel`. It wires the selected effect to existing use cases. The
application handler owns priority, exclusivity and follow-up order.

## Capture and ownership

An attachment modal and a name prompt make `capturesKeys` true. The native
router first replays any pending binding state, then sends new semantic keys
directly to the exclusive owner. Copy mode does not capture the router, so the
user's configured prefix bindings remain available.

Semantic keys use this order:

1. An attachment modal consumes every key. Escape closes it. Other keys are
   presentation no-ops.
2. The name prompt receives the key encoded with neutral terminal modes.
3. Copy mode receives the semantic key.
4. The focused pane receives the key and encodes it against its acknowledged
   child modes. After confirmed delivery, attachment prompt policy mirrors a
   marker deletion or prompt submission into the local preview store.

When the host reports a physical identity, the press records the selected
owner in a fixed 64-entry table. Pane ownership includes the delivered
`PaneId`. Repeat consults the table instead of current authority. Release takes
and removes the entry; prompts and copy mode consume it without a second edit,
while a pane receives it only when its keyboard protocol can encode it. An
orphan repeat or release is dropped.

A repeated press for the same identity replaces stale ownership. This recovers
from a release lost during a terminal transition. If the table is full, the new
press is dropped before any owner effect, the lifecycle remains unowned, and
telemetry increments `key_lease_overflows`.

Replayed bytes have already crossed semantic binding resolution. An empty
slice is ignored. The name prompt receives non-empty bytes first, copy mode
consumes them without an effect, and every remaining value reaches the pane.
The modal does not claim these prior buffered bytes. Its active capture applies
to new semantic keys.

A selected owner failure propagates and never falls through to another owner.
If the pane target disappeared or is exclusively owned, `PaneInputHandler`
returns no delivery and the route ends without another effect.

## Clipboard preview order

Only an unmodified `Ctrl+V` is eligible for local image inspection. The handler
first waits for `PaneInputHandler` to accept the input into the client outbox.
It starts the preview only after that confirmed delivery. A missing pane never
starts a preview.

Preview start is best effort. An unsupported platform, missing agent targets,
a busy capture, worker scheduling failure and other preview errors cannot
retract or fail the already accepted pane input. The media worker owns
clipboard access, PNG allocation and image validation outside the interactive
path. See [Clipboard image preview](clipboard-image.md).

## State, presentation and failure

The authority snapshot is valid only for a new press's synchronous handler
call. Active leases are client input state and survive configuration-router
replacement. Modal,
prompt and copy effects resolve their current owner again through their
capability adapter. No asynchronous task retains the snapshot or input slice.

A successful modal close advances `View.interactionVersion`. Prompt and copy
changes advance their own `ClientModel.Version` fields. `Presenter` observes
both through the paced loop. Pane input normally produces no presentation
revision unless its viewport policy commits a scroll change. Removing a paired
image marker also advances `View.interactionVersion`; removing the last marker
re-offers pane geometry. Claude and Pi marker identities are additionally
reconciled after committed pane frames: Claude's attachment context can remove
a chip without editing it as Codex text, and Pi's plain-text path yields to
word and line deletion bindings. Clipboard media follows its independent
ingress version.

Prompt, copy and pane failures preserve the transaction rules of their
existing handlers. The key router does not retry or reinterpret a failed
owner. A preview failure is the only swallowed error, and it occurs after pane
delivery.

## Proof

- `src/frontend/client/application/input/key_routing.zig` proves capture authority,
  semantic and byte priority, exact-pane leases, prompt repeat ownership,
  orphan and saturation policy, exclusive failures, confirmed delivery and
  `Ctrl+V` ordering.
- `src/frontend/input/keybind.zig` proves active editor capture before bindings,
  semantic replay, binding/application physical ownership, persistent prefix
  release, reload inheritance and bounded forwarding.
- `src/frontend/client/tests/input.zig` proves attachment-modal capture, prompt
  input, copy-mode keys, child-mode encoding, pane backpressure and `Ctrl+V`
  delivery through the complete input entrypoint.
- `name-prompt.md`, `copy-mode.md`, `pane-input.md` and `clipboard-image.md`
  prove each downstream owner and effect.
