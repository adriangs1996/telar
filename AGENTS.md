# telar

telar is an alternative to tmux for the era of agents. It is heavily inspired
by herdr (<https://github.com/herdrdev/herdr>). It brings to the table
a full runtime aware of agents and types of process that enhance the user's
control over what is running in his terminal. At the heart, it reduces to these
general components:

- A terminal multiplexer
- A pty-proxy
- Searchable and structured history
- Best effort integration with coding agents.
- An innovative and modern terminal UI focused on user awareness.

## Why is telar special ?

Unlike tmux, it does not settle for being only a multiplexer.
Unlike herdr, it tries to own the runtime of the agents instead
of cooperating with them based on hooks and lifecycle provided.

Like tmux, it is heavily customizable.
Top notch sidebar, close to a real GUI like T3 Code (<https://github.com/pingdotgg/t3code>)

## Architecture

Two processes. The split decides almost everything else, so get it right before
you add anything that crosses it.

### The runtime

One long-lived process per machine. It owns everything that has to survive the
UI dying: child processes and their ptys, one `vt.Terminal` per pane, what each
agent is currently doing, and the history.

A user closes their laptop lid, the client goes away, and the agents keep
working. That is the whole reason the runtime is separate, and it is the test
for whether a piece of state belongs here. Ask what happens to it when the TUI
is killed. If the answer is "the session is ruined", it belongs to the runtime.

### The client

It owns what only makes sense while somebody is looking: layout, which pane is
focused, hover, scroll position, selection, what a modal is covering. All of it
is disposable, because the runtime can rebuild everything that matters.

`examples/sidebar.zig` is a mock of this against invented data. It is not the
client, it proved the frontend can render core data.

### Code packages

The source tree enforces the process split before IPC exists. Both sides may
import `telar-core`. Backend and frontend never import each other. `src/main.zig`
is the temporary in-process bootstrap that composes them.

| Package          | Owns                                                               |
| ---------------- | ------------------------------------------------------------------ |
| `telar-core`     | cells, buffers, geometry, hit testing, focus, selection values    |
| `telar-backend`  | child processes, PTYs, terminal emulation, VT-to-cell translation |
| `telar-frontend` | host terminal, cell diff, input, pacing, editing, client platform  |

The module roots are `src/core/root.zig`, `src/backend/root.zig` and
`src/frontend/root.zig`. Put a type in core only when both processes need its
data or operations. Ownership of a value still follows the runtime/client rule
above; sharing its type does not make its state shared.

### One pane, end to end

The path a byte takes, because most decisions are really about where on it a
piece of code sits:

```
child ──pty──> vt.Terminal ──> vt.RenderState ──> blit ──> ui.Buffer
                                                              │
                                                     term.Screen diff
                                                              │
keystroke <── term.parse <── platform.Tty <──────────── real terminal
```

Two things fall out of that picture. The emulator decides what a screen _is_, so
telar never parses escape sequences from a child. And the diff is the last step
before bytes leave, so anything that wants to change what the user sees changes
the buffer, never the output stream.

### Two paths, two budgets

telar sits between the terminal emulator and the pty, and between the agent and
the network. Those are different paths and confusing them is the mistake this
section exists to prevent.

**The interactive path** carries a keystroke to the child and a byte of output
to a glyph. It is measured in microseconds and it allocates nothing. A frame is
capped at 60Hz by `pace`, and what does not fit gets folded rather than queued.

**The observation path** carries what an agent did into history: which tool it
called, what it asked the model, what came back. It is measured in "before the
user searches for it". It may allocate, it may block, it may be slow. What it
may never do is sit in the interactive path's way.

The test is easy to apply. If you find yourself parsing JSON while forwarding a
keystroke, you crossed the line. Move the work behind a queue and let the
keystroke go.

### The proxy, as built

`examples/proxy/`. Read it before writing the runtime; it settled these
questions already.

Outside the default build, because it links sqlite3 and libnghttp2 from the
system and the core builds with nothing but a Zig compiler. `zig build proxy`
and `zig build test-proxy` ask for it.

**`main.zig`** runs four actors feeding one event queue, and a main loop
that owns every piece of mutable state. Actors only move bytes.

```
input actor    stdin        -> user_input
output actor   pty master   -> the terminal, plus the OSC 133 tap
signal actor   wake pipe    -> resized
proxy actor    :PORT        -> upstream_opened / upstream_closed
```

**`osc.zig`** scans for OSC 133 shell markers. Framing is ours because
`vt.osc.Parser` consumes a payload and knows nothing about `ESC ]` or its
terminators; parsing is the emulator's.

**`ca.zig`** is a local authority that mints one leaf per host. It writes a
bundle of the system roots plus its own certificate, because `SSL_CERT_FILE`
replaces a trust store rather than extending it. No OpenSSL: X.509 issuance is
`tls.zig`'s.

**`tls.zig`** terminates both ends. It peeks the child's ClientHello for the
ALPN offer, negotiates upstream first, then mirrors the result downstream, so a
child never gets h2 to an HTTP/1.1 listener.

**`http.zig`** frames HTTP/1.1 half duplex, which is what the protocol already
is, so neither TLS session is touched by two threads. Chunked and
close-delimited bodies forward as they arrive, so SSE still streams. Secret
headers are redacted before anything is stored.

**`h2.zig`** observes rather than proxies. Frames relay byte for byte, with a
copy fed through nghttp2's standalone HPACK inflater. No sessions, no stream id
mapping, no flow-control windows. Enough to read the conversation, not enough to
alter it.

**`db.zig`** merges both taps onto one `event` table in SQLite: what the shell
ran and what went out over the network, ordered together.

Three things it does not do yet, and each is a decision rather than an oversight
waiting to happen. Response bodies are stored unredacted, and one of them has
already been observed carrying an API key. `timeline.db` lands in the working
directory with default permissions while holding prompts and replies in clear.
And interception is on with nothing on screen saying so.

One known failure: `ab.chatgpt.com` from Codex. Its binary links
Security.framework, which validates against the Keychain and ignores every
environment variable the proxy sets. Fixing it means installing the CA into the
system trust store, which is the user's decision and not the runtime's.

## Performance, no matter what

Doing so much work and placing between the terminal emulator and the actual pty,
adds latency. Users should not note that telar is proxying their requests, so,
functions should be heavily optimized. Strive to be obsessive about memory allocation
control, and watch out each function time complexity ( Big O ).

## Safety

telar runs continuously on user's devices, and might be used in a remote server,
so security is not negotiable. Prefer secure code over pretty or convenient code.
Watch out for memory problems. Take inspiration from Rust for keeping track of memory.

## Glossary

- you means the agent reading this file and changing telar.
- me is who you are talking to.
- user means the person using telar.
- agent means the coding agent a user runs inside a telar's pane. It could include you.
- client means the TUI that connects to a telar's server.
