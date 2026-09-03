# Agent rename

A user names a session inside the agent (`/name` in Pi, `/rename` in Claude
Code and Codex) and the sidebar row takes that name. The title has source
`agent`: it outranks a generated title, is checkpointed like a manual one, and
clearing the name inside the agent returns the row to its placeholder unless a
manual title was set afterwards. Every route ends in the same aggregate call,
so precedence and persistence live in one place.

## Pi

```text
/name <text> inside Pi
        |
telar.ts extension: session_info_changed { name }   (session_start carries the current name too)
        |
telar hook pi  -> mapPiTitle -> schema.report_agent_title
        |
routeReportAgentTitle -> ReportAgentTitleHandler -> Tracker.reportTitle -> Agent.reportTitle
        |
agent snapshot revision bump; checkpoint dirty
```

A cleared name arrives as `name: undefined` and is sent as an empty title.

## Claude Code

`/rename` fires no hook, so the name takes two routes.

```text
claude --name <text> | claude --resume of a named session
        |
SessionStart hook input: session_title
        |
telar hook claude -> mapClaudeTitle -> schema.report_agent_title   (same path as Pi)


/rename <text> while the session runs
        |
Claude appends {"type":"custom-title","customTitle":...,"sessionId":...} to transcript_path
        |
every Claude hook: transcript_path rides on schema.report_agent as session_file, kind claude_transcript
        -> ReportAgentHandler -> Tracker.observeReport -> session_file.Watches.put
        |
maintenance tick: tickSessionNames -> Tracker.nextSessionFileProbe (stalest due, one in flight)
        -> select.concurrent(.session_name, session_name.probe)   [observation path]
        |
probe reads the bytes appended since the last offset (at most 64 KiB) and
transcript.scan keeps the last custom-title line for the session
        |
event session_name -> sessionNameCompleted -> Tracker.finishSessionFileProbe
        -> Agent.reportTitle; checkpoint dirty; clients pumped
```

The watch is keyed by the exact pane generation and the session reference the
hooks reported. Its first probe only records where the file ends, so names
already in the transcript are not replayed; the `SessionStart` title covers a
resumed named session. Claude Code creates the transcript lazily, so a file
that does not exist at the first probe is seeded at zero and read whole once
it appears: a rename before the first prompt is the common case. Lines are skipped by prefix without parsing, a title
line longer than 4 KiB is ignored, a file shorter than the offset is read
again from the start, and a missing file leaves the offset untouched. The
probe interval is one second; it costs one `open` and one `length` per
watched Claude agent when nothing was appended. Claude Code's documentation
says the transcript is written asynchronously; measured on 2.1.259, the
`custom-title` line was on disk within the first poll after Enter.

Only the `sessionId` of the agent's own reference is accepted, so a line from
a forked or foreign session never renames the pane. The watch dies with its
agent: `removeStored` drops it and a probe whose agent is gone is discarded.

## Codex

`/rename` fires no hook and, measured under a pty on 0.153.0, leaves the
terminal title at the directory name. The name lands at once in
`threads.name` of Codex's state database, so that database is the session
file the hooks report.

```text
/rename <text> inside Codex
        |
Codex updates threads.name for the thread id in $CODEX_HOME/state_<n>.sqlite
        |
every Codex hook: telar hook codex resolves the newest state_<n>.sqlite under
CODEX_HOME (else ~/.codex) and sends it as session_file, kind codex_state
        -> ReportAgentHandler -> Tracker.observeReport -> session_file.Watches.put
        |
maintenance tick: tickSessionNames -> Tracker.nextSessionFileProbe
        -> select.concurrent(.session_name, session_name.probe)   [observation path]
        |
probe opens the database read-only and runs
SELECT name FROM threads WHERE id = ?1 for the hook's session id
        |
event session_name -> sessionNameCompleted -> Tracker.finishSessionFileProbe
        -> Watch.remember drops an unchanged name -> Agent.reportTitle
```

Unlike the transcript, the database is read whole every second, so the watch
remembers the last name it handed over and only a change reaches the agent.
The first probe therefore titles a resumed named thread without any
`SessionStart` help, and a NULL name arrives as an empty title.

Codex 0.153 runs its `SessionStart` hook only when the first prompt is
submitted, right before `UserPromptSubmit`, not when the TUI starts; measured
with an isolated `CODEX_HOME` whose hooks captured their stdin. Until that
first prompt no hook has told the runtime where the thread lives, so a name
given before it appears with the first prompt, when the watch's first probe
reads the current row. Hooks trusted while a session is already running have
the same effect: Codex skips untrusted hooks, and the trust takes effect at
the next event. The reader
opens with `SQLITE_OPEN_READONLY`, a 200 ms busy timeout, and Codex keeps the
file in WAL mode, so the probe never blocks Codex and a busy or missing
database simply reports nothing. The schema number in the file name and the
`threads.name` column are Codex internals; a future Codex can move them and
the probe then degrades to reporting nothing.

## Ownership and bounds

- Owner: runtime. The client only renders the title source it receives.
- Budget: observation. The hook process and the transcript probe never touch
  the interactive path; the completion applies one bounded aggregate change.
- Authority: only the pane generation that hosts the agent may report a title
  or a transcript path; a stale generation fails with `pane_not_found`.
- Bounds: 96-byte titles cut on a UTF-8 boundary, 1 KiB session-file paths,
  one watch per agent record, one probe in flight, 64 KiB per transcript
  probe, one row per database probe.
- Recovery: a restart resumes the agent and its `SessionStart` hook reports
  the current name and transcript again; the checkpoint carries the last
  ready title.

## Proof

- `src/backend/agent/agent.zig` and `tracker.zig` prove precedence, clearing,
  durability, watch registration, single-flight probing, stale discard and
  that a re-read name never undoes a later manual title.
- `src/backend/agent/session_file.zig` proves the bounded watch store and the
  last-name memory.
- `src/backend/agent/transcript.zig` proves the scan: last line wins, partial
  lines wait, foreign sessions and malformed lines are skipped, long names are
  bounded.
- `src/backend/runtime/application/session_name.zig` proves both probes
  against real files: transcript seeding at the end, reading only appended
  lines, idling, rewritten and missing files; database names, NULL names,
  unknown threads and missing databases.
- `src/cli/hook.zig` proves the Pi and Claude title mappings, that the
  transcript path rides on every Claude report within its bound, and that the
  Codex hook resolves the newest `state_<n>.sqlite`.
- `src/core/schema_contract_test.zig` pins `report_agent_title` and the
  extended `report_agent` bytes.
