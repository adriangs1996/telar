---
status: superseded
---

# Own agent panes in the runtime

Superseded: telar removed agent panes. Agents run in terminal panes, and telar
follows them through official hooks, process and screen evidence.

An agent pane owns a structured conversation, separate from a terminal pane's
PTY. The runtime starts Codex app-server with pipes, retains its latest bounded
conversation snapshot and handles prompts, cancellation and approval responses.
Closing a GUI connection does not close that process. The client owns its draft,
selection and transcript scroll.

Pane kind is runtime state. Pane surface remains presentation state. A terminal
pane may show the existing thread projection, but toggling a surface cannot
convert a terminal process into a managed agent.

The initial product exposes agent creation and interaction only in the GUI.
`prefix + a` creates a new tab in the current workspace with one agent pane.
The shared client still owns the commands and conversation projection, and the
runtime reports the agent through the existing sidebar registry. The TUI has
no equivalent controls yet.

## Conversation source

Codex app-server supplies authoritative streamed items and lifecycle events.
Its adapter normalizes them into provider-independent messages and states.
Provider JSON parsing, process I/O and request waiting run in a bounded worker
outside terminal input and rendering. A coalesced change notification wakes the
runtime; clients receive snapshots without polling idle conversations.

The retained text is a bounded in-memory presentation cache. Codex remains the
owner of its durable transcript. This extends [ADR 0010](0010-index-agent-transcripts-instead-of-copying-them.md)
for managed agents without adding response text to Telar's history database.
Reattaching to a live runtime restores the current conversation. Runtime crash
recovery is a separate concern from keeping work alive when the GUI disconnects.

## Authority

Prompts, interruption and approvals carry pane identity and runtime generation.
Approval responses also name the exact pending request. Neither provider output
nor terminal heuristics can approve work. Unsupported server requests fail
explicitly. Codex manages authentication. The initial managed thread uses
workspace-write permissions and explicit user review of untrusted operations.

The [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server)
defines the protocol. The initial adapter is checked against the schema emitted
by the installed Codex CLI 0.154.0.
