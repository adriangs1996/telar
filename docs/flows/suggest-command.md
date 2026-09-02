# Command suggestion

`prefix+?` opens a palette that asks the runtime's [engine](engine.md) for
one shell command. The user types what they want, Enter asks, and Enter on
the answer pastes it into the focused pane without running it. The human
still presses Enter in the shell: the engine suggests, it never executes.

## Ask

```text
suggest_command action
        |
suggestions.begin -> name prompt (target .suggest) + model.suggestion.begin
        |
Enter with text -> name_prompts.submit(.suggest) -> suggestions.request
        |
model.suggestion.expect(request id)  (phase waiting, prompt stays open)
        |
outbox suggest_command { request_id, focused pane, text ≤ 512 bytes }
        |
runtime routeSuggestCommand (ui request class)
        |
Pane.dumpText(24 visible rows) + pane cwd + text -> suggestion.buildPrompt
        |
engine.Service.submit (purpose = suggestion { client key, request id })
```

Enter is inert while a reply is pending and while the field is empty with no
suggestion. Editing the text after a reply discards it, so the next Enter
asks again instead of pasting a stale answer. The prompt closes only on
Escape or on Enter over a ready suggestion.

The runtime never fails the request through `request_failed`: an absent
engine, a missing pane, a full engine ring or a prompt that cannot be built
all answer `command_suggestion` with a status, so the palette shows the
reason and consumes no request continuation.

## Reply

```text
Event.engine_response (observation path)
        |
AgentEvents.handleEngineResponse -> deliverSuggestion
        |
suggestion.extractCommand: first non-empty line, fences stripped, ≤ 1024 bytes
        |
ResponseQueue command_suggestion { request_id, status, text }  (client gone: dropped)
        |
client suggestions.apply -> model.suggestion.apply(request id, status, text)
        |
Version.suggestion -> presenter invalidate -> list modal frame
```

Only the awaited request id lands; a reply after the palette closed changes
nothing visible. A ready reply with usable text renders as the single
selected row; any other status renders its reason and Enter asks again.

## Paste

Enter over a ready suggestion first closes the prompt, then pastes the text
through the ordinary pane-paste path (`pane_inputs.expressionPaste`),
without a trailing Enter. The order matters for the same reason as the
history palette: `planPaneInput(.focused)` refuses input while a prompt
owns it.

## Privacy and bounds

The prompt carries the pane's cwd, its last 24 visible rows (at most 4 KiB,
oldest rows dropped first) and the request. Configuring `runtime.engine` is
the opt-in for all of it; without an engine the palette says so and sends
nothing to a model. The request is bounded on the wire at 512 bytes and the
suggestion at 1024; the engine's own prompt and reply caps bound the rest.

## Proof

- `src/backend/runtime/application/suggestion.zig` proves prompt bounds and
  reply reduction.
- `src/frontend/client/model/suggestion.zig` proves stale-reply rejection,
  edit invalidation and failure phases.
- `src/frontend/client/model/name_prompt.zig` proves the palette's submit
  and selection commands.
- `src/frontend/client/tests/graphics_and_clipboard.zig` proves a stray
  suggestion is ignored without ending the client.
- `src/core/schema_contract_test.zig` pins both messages and bumps the
  handshake fingerprint.
