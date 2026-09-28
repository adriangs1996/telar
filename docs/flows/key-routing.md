# Key routing

The shared router returns a tagged `Decision`: `action`, `forward`, `replay`,
`pending` or `discard`. It has no application callback or handler parameter.
`Context` supplies current capture and repeat policy as data. The window and
the headless client execute each decision before routing the next event,
including within a single drain turn. A focus change or newly opened prompt
therefore affects the next key.

The router owns bounded input/chord buffers, the compiled keymap and physical
binding leases. It allocates no heap storage while routing. Both adapters build
it through `client.key_router` (`src/client/input/key_router.zig`) without an
escape decoder: they hand it semantic keys, so no client parses terminal escape
sequences.

## End-to-end path

```text
window:   GuiAdapter.drainInput → dispatchKey → routeKey
headless: HeadlessClient.take (stdin key or text line) → press
                                        |
                              router.routeEvent(event, context)
                                        |
                                   Decision
                                        |
                          adapter decision switch
                          /                         \
                    action request             key / replay
                          |                         |
             actions.executeAction          key_routing.routeKeyInput
                          |                         |
                concrete operation         retained application owner
                          |                         |
           actionCompleted(post-action policy)   pane_input.sendPaneInput
```

`GuiAdapter.executeAction` also applies native palette and sidebar behavior.
`InputQueue` owns bounded event storage, payload pools and retained releases.
`GuiAdapter` owns the router, binding target, timer and binding presentation revision.
The queue has no application argument or owner pointer. `GuiAdapter.drainInput` borrows
its front event and calls `consume` only after processing completes. Partial
scroll and clipboard delivery retain the front event. Binding expiry,
configuration adoption and cancellation also enter `GuiAdapter` directly.

GUI input draining, action execution, focus handling, GPU completion and worker
completion are private operations reached through `update` and its event dispatch.
GUI integration tests admit input and post completion messages to that same inbox;
they do not invoke those private steps directly.

`key_routing.keyRoutingAuthority()` snapshots modal, prompt and copy-mode
flags. The existing pure `key_routing.captures(authority)` decides whether bindings are
bypassed. `actions.repeatPane()` returns only the eligible attached pane
ID, or null when an exclusive owner, copy mode or an unavailable pane prevents
repetition. The pure `action_routing.repeatPolicy(action, eligible_pane)` receives these values,
never an application pointer. Both adapters re-read eligibility after each
action so a focus or mode change takes effect before the next repeat.

Window pointer, paste and clipboard events are handled explicitly in
`GuiAdapter.drainInput`. Startup retains early user input without a callback
object: `drainInput` returns while `StartupState.holdsInput` is true, and the
headless client reads no stdin line until then.

`key_routing.routeKeyInput` reads current authority and retained physical leases, then
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

`KeyRoutingCommand.bytes` remains for byte input that has already crossed
binding resolution. An empty slice is ignored. The name prompt receives
non-empty bytes first through `HostInputSource.routePromptBytes`, copy mode
consumes them without an effect, and every remaining value reaches the pane.
The modal does not claim bytes. Neither the window nor the headless client
produces byte commands today; both send semantic keys.

A selected owner failure propagates and never falls through to another owner.
If the pane target disappeared or is exclusively owned, `pane_input.sendPaneInput`
returns no delivery and the route ends without another effect.

## Held scroll bindings

The host obtains the pure `repeatPolicy(action, eligible_pane)` after successful
execution and
passes it to `router.actionCompleted`. Only native
`scroll_pane` actions opt in, with a 100 ms interval and the current `PaneId`
as their owner token. Prompts, attachment modals, copy mode and
missing or detached panes deny repeat authority. The initial action runs
normally before repeat authority is captured, so scroll can first exit copy
mode through the existing native action dispatch. Both taps and held bindings
target the focused pane.

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

This needs a physical key lifecycle. The window reports press, repeat and
release with a physical identity. The headless client sends presses only, so a
held binding never repeats there. See
[Configuration](../configuration.md) and [Pane mouse input](pane-mouse-input.md).

## Clipboard preview order

Only an unmodified `Ctrl+V` is eligible for local image inspection. The operation
first waits for `pane_input.sendPaneInput` to accept the input into `model.to_runtime`.
It starts the preview only after that confirmed delivery. A missing pane never
starts a preview.

Preview start is best effort. An unsupported platform, missing agent targets,
a busy capture, worker scheduling failure and other preview errors cannot
retract or fail the already accepted pane input. Neither the window nor the
headless client supports capture, so today the start returns `unsupported`.
See [Clipboard image preview](clipboard-image.md).

## State, presentation and failure

The authority snapshot is valid only for a new press's synchronous operation
call. Active leases are client input state and survive configuration-router
replacement. Modal,
prompt and copy effects resolve their current owner again through their
capability adapter. No asynchronous task retains the snapshot or input slice.

Prompt and copy changes advance their own `Version` fields, read through
`ClientModel.version()`. The adapter observes them after the turn through
`Client.presentation.observe`. Pane input normally produces no presentation
revision unless its viewport policy commits a scroll change. With a bound
attachment shelf, removing a paired image marker re-offers pane geometry, and
Claude and Pi marker identities are reconciled after committed pane frames; no
current adapter binds one.

Prompt, copy and pane failures preserve the transaction rules of their
existing operations. The key router does not retry or reinterpret a failed
owner. A preview failure is the only swallowed error, and it occurs after pane
delivery.

## Validation

- `src/model/input/key_routing.zig` proves capture authority.
- `src/client/input/key_lease.zig` proves exact-owner leases, replacement and
  saturation policy; `lib/keyinput/routing_tests.zig` proves binding
  ownership through release and that repeats arm only after execution.
- `lib/keyinput/GenericRouter.zig` and `routing_tests.zig` prove binding
  admission, semantic replay, binding/application physical ownership,
  persistent prefix handling and keymap replacement without decoders.
- `src/client_tests/input.zig` proves child-mode encoding, prefix release
  through client routing, detach and prompt opening inside one batch, and
  held-scroll behavior: both viewport directions, burst suppression, endpoint
  no-ops, global bindings, changed focus and copy-mode capture.
- `src/client_tests/configuration.zig` proves attachment-modal capture against a
  test shelf and `Ctrl+V` delivery without a preview target.
- `src/client/input/action_routing.zig` proves that only
  native scroll actions receive a repeat policy and exact-pane owner token.
- `name-prompt.md`, `copy-mode.md`, `pane-input.md` and `clipboard-image.md`
  prove each downstream owner and effect.
