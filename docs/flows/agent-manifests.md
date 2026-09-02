# Agent manifests

Which processes are agents and which screen phrases mean working, blocked or
ready is data, not code. `telar-core` owns a bounded manifest table with
built-in entries for `claude`, `codex` and `pi`; `config.runtime.agents` adds agents
or extends the built-in phrase lists without a rebuild.

## End-to-end path

```text
config.lua  runtime.agents = { { name = "gemini", ... } }
        |
config.root.parseAgentManifests -> RuntimeSnapshot.agent_manifests (Table)
        |
telar server: Launch.agent_manifests -> runtime Options.agent_manifests
        |
Resources.agent_manifests (immutable after startup)
        |
Application.agent_manifests --> PaneLauncher --> Pane.manifests
        |                                            |
        |                        history.Observer.detector.signal(table)
        |                        process.probe(.{ .manifests = table })
        |
Delivery.prepare: AgentSnapshotEntry.provider_name = table.providerName(provider)
        |
clients and `telar agent` render the name; icons and placeholders stay generic
for agents without built-in artwork
```

## Table

`core.agent_manifest.Table` holds at most `schema.max_agent_manifests`
manifests. Each manifest names the agent and carries bounded lists:
`process_names` (executable basenames without launcher suffixes),
`process_paths` (entry-point path fragments for interpreter launches),
`brand` (attributes a generic working or blocked phrase to this agent),
`identity` (confirms identity on screen without proving readiness), `working`,
`blocked` and `ready_prompt` (proves the agent is idle and waiting).

`Table.detect` keeps the historical precedence: any blocked phrase, then any
working phrase, then a ready prompt, then identity alone. `builtin_table` is a
comptime constant that reproduces the exact Claude Code and Codex heuristics
the runtime shipped with before manifests existed.

Provider identity on the wire is `schema.AgentProvider`, now non-exhaustive.
`claude` and `codex` keep their values; configured agents take indexes from
`schema.first_custom_agent_provider` in configuration order. The snapshot
entry carries `provider_name`, so a client never needs the table to label an
agent.

## Ownership and budgets

The table is copied once into runtime resources and only borrowed afterwards:
observation workers read it by pointer, so detection stays allocation-free.
Configuration validates names (lowercase, 1..32 bytes, unique unless
extending a built-in) and every phrase (printable UTF-8 within the list
bounds) before the runtime starts; an invalid manifest is a configuration
error, never a partially loaded table.

Proxy provider identification is unchanged: only the built-in providers have
network-side turn detection, because parsing an SSE stream is provider code,
not a phrase list.

The proxy names the API family it saw on the wire, not the agent. Pi talks to
Anthropic, OpenAI or other hosts from one process, so once a process has
claimed a pane its exchanges count whatever the host says; the wire family
only decides identity while no process is known. `pi` is the third built-in
manifest. It is identified by its executable name and the
`pi-coding-agent` entry-point path under either npm scope, and it carries no
screen phrases or brand word because Pi renders no permission prompts and the
word "pi" occurs inside "api" and "pipe".

## Proof

- `src/core/agent_manifest.zig` proves the built-in heuristics, custom index
  assignment, extension by name and list bounds.
- `src/backend/history/agent_detection.zig` and `src/backend/process/root.zig`
  prove screen and process detection against the built-in table.
- `src/frontend/config/root.zig` proves manifest parsing and its diagnostics.
