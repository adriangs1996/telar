---
status: accepted
---

# Index agent transcripts instead of copying them

The conversation view needs a readable transcript of each thread. Three
sources were available: the agent's own session files, the proxied model
traffic, and the pane's screen. We decided to read the agent's files and to
persist only an index.

## Decision

Per-provider session readers tail the agent's own transcript (Claude Code
JSONL, Codex rollouts, Pi sessions, opencode SQLite later) by offset, in
observation workers, with a per-line cap and a skip policy. telar's history
database stores one `thread` row per conversation and one `thread_item` row
per normalized entry: kind, tool pairing, timestamps, file offset, byte length
and a 512-byte preview. The full text is read on demand from the agent's file
with a 64 KiB cap. Full-text search covers user-authored previews only.

## Considered options

- Reconstructing conversations from the proxy: works for the Anthropic
  Messages API with request deduplication, but Codex sends incremental
  turns over a WebSocket with `store=false`, compaction erases earlier
  history from the traffic, subagents share the pane credential, and side
  calls (title generation, suggestions) pollute the stream. The proxy stays
  what it is: lifecycle and command evidence.
- Screen scraping: alternate-screen agents leave nothing in scrollback, and
  the screen has no structure. It stays a lifecycle fallback.
- Copying transcript text into telar's database: measured session
  directories on one machine hold 6.6 GB of Codex rollouts alone, and the
  invariants forbid persisting response bodies until a redaction and
  retention policy exists.

## Consequences

- Hooks are the link between a pane and its file; a thread without a hook
  report has no transcript path and the view says so.
- Anthropic documents the JSONL as internal; readers ignore unknown record
  types and degrade the view to "unavailable" instead of failing.
- Search over model output is not available until a redaction policy
  permits indexing it.
