# Agent manifests

What Telar knows about a coding agent is split along three axes, and each axis
has one home. Adding an agent touches the first axis only; the other two are
code and stay with the built-ins.

| Axis | Home | Answers |
| --- | --- | --- |
| Data | `core.agent_manifest.Table` (`config.runtime.agents`) | Which process and phrases are this agent; how it is named, titled and drawn; how its prompt marks pasted images |
| Runtime capabilities | `backend/agent/providers/` (one file per built-in) | How a session is resumed; which lifecycle quirks the aggregate tolerates |
| API dialect | `backend/proxy/provider/dialect.zig` | Which wire protocol an exchange speaks (`anthropic_messages`, `openai_responses`) |

The sidebar, the `telar agent` command, notifications and the image shelf read
the data axis from the snapshot entry the runtime publishes. None of them
switch on a provider index any more; the only remaining switches are the
artwork registries (`ui.icons.Icon.forProvider`, `kitty.SidebarProvider`),
which map a built-in to its shipped image and fall back to the manifest glyph
or a generic mark for everything else.

## End-to-end path

```text
config.lua  runtime.agents = { { name = "gemini", display_name = "Gemini CLI", icon = "G", ... } }
        |
config.agents.parse -> RuntimeSnapshot.agent_manifests (Table)
        |
telar server: Launch.agent_manifests -> runtime Options.agent_manifests
        |
Resources.agent_manifests (immutable after startup)
        |
Application.agent_manifests --> PaneLauncher --> Pane.manifests
        |                                            |
        |                        history.Observer.detector.signal(table)
        |                        history.prompt_scan.scanReadyPrompt(terminal)
        |                        process.probe(.{ .manifests = table })
        |                                 (foreground name = table.displayName)
        |
Delivery.prepare: entry.provider_name  = table.providerName(provider)
                  entry.display_name   = table.displayName(provider)
                  entry.icon           = table.icon(provider)
                  entry.attachments    = table.attachments(provider)
                  entry.session_title  = table.placeholderTitle(provider) while no title exists
        |
clients render display_name, icon (or built-in artwork) and bind image
previews with attachments; `telar agent` prints provider_name
```

The agent aggregate itself never sees the table. It stores the generic
placeholder (`agent_manifest.generic_placeholder`) and the provider index;
delivery attaches the presentation, next to the workspace and tab labels it
already adds. That keeps manifest data out of the checkpoint and out of the
projection's hot path.

## Table

`core.agent_manifest.Table` holds at most `schema.max_agent_manifests`
manifests. Each manifest names the agent and carries:

- identity: `process_names` (executable basenames without launcher suffixes),
  `process_paths` (entry-point path fragments for interpreter launches),
  `brand`, `identity`, `working`, `blocked` and `ready_prompt` phrase lists;
- presentation: `display_name` (defaults to the name), `placeholder`
  (defaults to "New <display name> session") and `icon` (one glyph, empty
  means client artwork);
- capability: `attachments`, the marker scheme of pasted images
  (`none`, `ordered`, `stable_number`, `pasted_path`).

`Table.detect` keeps the historical precedence: any blocked phrase, then any
working phrase, then a ready prompt, then identity alone. The observation
worker runs it on `history.agent_detection.Sample`, the plain text of the
history emulator's active screen after each batch, never on the raw bytes: a
client that repaints only changed cells can emit its idle prompt without the
status line still drawn above it, and only the screen holds both. An agent that
declares `ready_prompt` phrases (`Table.declaresReadyPrompt`) is exempt from
the generic prompt-glyph scan in `history.prompt_scan`, because its manifest
already proves readiness. `builtin_table` is a comptime constant that
reproduces the exact Claude Code and Codex heuristics the runtime shipped with
before manifests existed, plus each built-in's display name and attachment
scheme.

Provider identity on the wire is `schema.AgentProvider`, non-exhaustive.
`claude`, `codex` and `pi` keep their values; configured agents take indexes
from `schema.first_custom_agent_provider` in configuration order. The snapshot
entry carries `provider_name`, `display_name`, `icon` and `attachments`, so a
client never needs the table.

## Runtime capabilities

`backend/agent/providers/root.zig` resolves `Capabilities` for a provider:
`resume_prefix` (the shell words `session_checkpoint.resumeCommand` types in
front of a UUID) and `ready_prompt_settles_report` (Codex reports `working`
from its `Stop` hook, so only its newer input prompt ends that report). Each
built-in has one file; every other provider resolves to `default`, which
claims nothing. Only this table can ever produce a resume command.

Lifecycle hooks are the CLI's own per-agent table: `telar integration`
installs them from `cli/integration.zig` and `telar hook` parses them in
`cli/hook.zig`. Pi uses an extension instead of hook settings.

## API dialect

The proxy never names an agent. `provider/dialect.zig` identifies the dialect
of a CONNECT host and `request.classify` decides inference routes per dialect.
Observations carry the dialect to the runtime, where
`ProxyObservation.impliedProvider` maps it to the native built-in agent
(`anthropic_messages` to Claude Code, `openai_responses` to Codex). That
implied identity is used only while no process has claimed the pane; once a
process is known, its exchanges count whatever the host says, so Pi talking to
Anthropic stays Pi and a Codex pointed at a compatible gateway stays Codex.

## Ownership and budgets

The table is copied once into runtime resources and only borrowed afterwards:
observation workers and delivery read it by pointer, so detection and
enrichment stay allocation-free. Configuration validates names (lowercase,
1..32 bytes, unique unless extending a built-in), every phrase (printable
UTF-8 within the list bounds), presentation strings (printable, bounded; the
icon exactly one cell wide) and the attachment scheme before the runtime
starts; an invalid manifest is a configuration error, never a partially loaded
table.

## Proof

- `src/core/agent_manifest.zig` proves the built-in heuristics, custom index
  assignment, extension by name, list bounds and presentation defaults.
- `src/backend/agent/providers/root.zig` proves capability resolution.
- `src/backend/proxy/provider/dialect.zig` proves host identification and the
  implied agent per dialect.
- `src/backend/history/agent_detection.zig` and `src/backend/process/root.zig`
  prove screen and process detection against the built-in table.
- `src/frontend/config/generation.zig` proves manifest parsing and its
  diagnostics, including the presentation fields.
