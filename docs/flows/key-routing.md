# Key routing

The shared router returns a tagged `Decision`: `action`, `forward`, `replay`,
`pending` or `discard`. It has no application callback or handler parameter.
`Context` supplies current capture and repeat policy as data. The GUI and TUI
execute each decision before routing the next event, including within a single
host read. A focus change or newly opened prompt therefore affects the next key.

The router owns bounded input/chord buffers, the compiled keymap and physical
binding leases. It allocates no heap storage while routing. Host bytes borrowed
from `next` remain valid until the next decoder call. The TUI forwards decoded
keys; malformed host escape sequences never reach the child verbatim.

## End-to-end path

```text
GUI: GuiClient.drainInput → dispatchKey → routeKey
TUI: host_inputs.handleRead → feed → router.next → decoded
                                        |
                              router.routeEvent(event, context)
                                        |
                                   Decision
                                        |
                             host decision switch
                          /                         \
                    action request             key / replay
                          |                         |
             AttachedClient.executeAction          key_routing.apply
                          |                         |
                concrete operation         retained application owner
                          |                         |
           actionCompleted(post-action policy)   pane_inputs.send
```

`GuiClient.executeAction` also applies native palette, sidebar and transcript behavior.
`InputQueue` owns bounded event storage, payload pools and retained releases.
`GuiClient` owns the router, binding target, timer and binding presentation revision.
The queue has no application argument or owner pointer. `GuiClient.drainInput` borrows
its front event and calls `consume` only after processing completes. Partial
scroll and clipboard delivery retain the front event. Binding expiry,
configuration adoption and cancellation also enter `GuiClient` directly.

GUI input draining, action execution, focus handling, GPU completion and worker
completion are private operations reached through `update` and its event dispatch.
GUI integration tests admit input and post completion messages to that same inbox;
they do not invoke those private steps directly.

`AttachedClient.keyRoutingAuthority()` snapshots modal, prompt and copy-mode
flags. The existing pure `captures(authority)` decides whether bindings are
bypassed. `AttachedClient.repeatPane()` returns only the eligible attached pane
ID, or null when an exclusive owner, copy mode or an unavailable pane prevents
repetition. The pure `repeatPolicy(action, eligible_pane)` receives these values,
never an application pointer. GUI and TUI re-read eligibility after each action
so a focus or mode change takes effect before the next repeat.

A failed widget chord replays to its original widget identity; it cannot type
into a newly focused composer. TUI mouse, paste and terminal responses are
handled explicitly in `host_inputs.decoded`. Startup input similarly yields
host responses while retaining early user input, without a callback object.

`key_routing.apply` reads current authority and retained physical leases, then
calls the selected concrete operation. Priority, exclusivity and follow-up order
are visible in the same module.

## Capture and ownership

An attachment modal and a name prompt make `Context.captures_keys` true. The native
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
If the pane target disappeared or is exclusively owned, `pane_inputs.send`
returns no delivery and the route ends without another effect.

## Held scroll bindings

The host obtains the pure `repeatPolicy(action, eligible_pane)` after successful
execution and
passes it to `router.actionCompleted`. Only native
`scroll_pane` actions opt in, with a 100 ms interval and the current `PaneId`
as their owner token. Prompts, attachment modals, copy mode and
missing or detached panes deny repeat authority. The initial action runs
normally before repeat authority is captured, so scroll can first exit copy
mode through the existing native action dispatch. In the GUI, agent pane scroll
bindings use the delivered transcript's wheel policy, including its scroll
limit, disclosure-anchor cancellation and history navigation. Both taps and
held bindings target the focused pane and leave its composer unchanged.

The client router retains one owned action, its final physical key and chord,
its policy and its last execution timestamp. A matching binding-owned repeat
rechecks authority and modifiers before checking elapsed monotonic time. A due
repeat returns the captured action for the host to execute; it never
re-runs keymap matching or requires the prefix again. Excess events are dropped.
A late batch produces one step, with no timer, allocation or catch-up queue.
The existing 64-entry lease table still bounds physical ownership.

Release clears the held action but remains consumed by its binding lease.
Another press, mouse input, paste, router replacement, changed authority or
chord modifiers cancels repetition. A failed repeat also cancels it. Reload
inherits ownership but never the old repeat action. No repeated event means
no scroll work, even if the host loses a release. Ordinary taps stay immediate.
Client detach or destruction discards the state; neither IPC nor runtime state
changes. Repeated scroll uses the existing viewport or child-input flows.

This needs a physical lifecycle from the host. Current Kitty flags 7 report
modified chords such as `alt+-`, but leave plain text suffixes as text.
Legacy press-only input retains its old behavior. See
[Configuration](../configuration.md) and [Pane mouse input](pane-mouse-input.md).

## Clipboard preview order

Only an unmodified `Ctrl+V` is eligible for local image inspection. The operation
first waits for `pane_inputs.send` to accept the input into the client outbox.
It starts the preview only after that confirmed delivery. A missing pane never
starts a preview.

Preview start is best effort. An unsupported platform, missing agent targets,
a busy capture, worker scheduling failure and other preview errors cannot
retract or fail the already accepted pane input. The media worker owns
clipboard access, PNG allocation and image validation outside the interactive
path. See [Clipboard image preview](clipboard-image.md).

## State, presentation and failure

The authority snapshot is valid only for a new press's synchronous operation
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
existing operations. The key router does not retry or reinterpret a failed
owner. A preview failure is the only swallowed error, and it occurs after pane
delivery.

## Validation

- `src/client/application/input/key_routing.zig` proves capture authority,
  semantic and byte priority, exact-pane leases, prompt repeat ownership,
  orphan and saturation policy, exclusive failures, confirmed delivery and
  `Ctrl+V` ordering.
- `src/frontend/input/keybind.zig` proves active editor capture before bindings,
  semantic replay, binding/application physical ownership, persistent prefix
  release, reload inheritance, repeat pacing, cancellation, clock bounds,
  arbitrary repeat-report splits and bounded forwarding.
- `src/frontend/client/tests/input.zig` proves attachment-modal capture, prompt
  input, copy-mode keys, child-mode encoding, pane backpressure and `Ctrl+V`
  delivery through the complete input entrypoint. Held-scroll tests cover both
  viewport directions, burst suppression, endpoint no-ops, global bindings,
  changed focus and copy-mode capture through the router and real adapters.
- `src/client/application/input/action_routing.zig` proves that only
  native scroll actions receive a repeat policy and exact-pane owner token.
- `src/gui/tests/widget_interaction.zig` proves agent scroll bindings through
  the native input entrypoint, paced repetition, transcript bounds, stale
  attachment rejection and preservation of composer text.
- `name-prompt.md`, `copy-mode.md`, `pane-input.md` and `clipboard-image.md`
  prove each downstream owner and effect.
