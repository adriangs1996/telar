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

Before changing lifecycle, IPC, PTY/VT/input, graphics, agents, persistence,
history/proxy, Lua/plugins, or performance, read
[`docs/engineering-invariants.md`](docs/engineering-invariants.md) and apply
every rule relevant to the change.

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

| Package          | Owns                                                              |
| ---------------- | ----------------------------------------------------------------- |
| `telar-core`     | cells, buffers, geometry, hit testing, focus, selection values    |
| `telar-backend`  | child processes, PTYs, terminal emulation, VT-to-cell translation |
| `telar-frontend` | host terminal, cell diff, input, pacing, editing, client platform |

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

### Three paths, three budgets

telar sits between the terminal emulator and the pty, and between the agent and
the network. Graphics add bulk media between applications and the host terminal.
These paths have different budgets and never wait on one another.

**The interactive path** carries a keystroke to the child and a byte of output
to a glyph. It is measured in microseconds and it allocates nothing. A frame is
capped at 60Hz by `pace`, and what does not fit gets folded rather than queued.

**The media path** carries KGP payloads, decoded images, compression and image
transfer. It is measured in frame deadlines. It may allocate within strict
quotas, runs behind its own bounded queues, and never delays input or cell
output. Repeated frames replace obsolete work rather than building a replay.

**The observation path** carries what an agent did into history: which tool it
called, what it asked the model, what came back. It is measured in "before the
user searches for it". It may allocate, it may block, it may be slow. What it
may never do is sit in the interactive path's way.

The test is easy to apply. Parsing JSON or decompressing a large image while
forwarding a keystroke crosses a budget. Move the work to its queue and let the
keystroke go.

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

## Code Style

- Do not end function's signature's parameter list with a ",".
- Always write the function's signature on a single line.

```zig
// BAD
pub fn observeProxy(
  store: *Store,
  observation: ProxyObservation,
) bool { }

// GOOD
pub fn observeProxy(store: *Store, observation: ProxyObservation) bool {}
```

- Add comments only on non-trivial and behavior rich methods. Always include
  example of usage in comments for public methods.
- Always leave a blank line between blocks of code inside a method.
  Example:

```zig
// Bad
    pub fn observeProxy(store: *Store, observation: ProxyObservation) bool {
        if (observation.provider == .unknown) {
            return false;
        }
        var record = switch (observation.phase) {
            .request_started => store.ensure(observation.identity) orelse return false,
            .response_activity, .response_finished, .request_failed => store.find(observation.identity.key) orelse return false,
        };
        const request: ProxyRequest = .{
            .protocol = observation.exchange.protocol,
            .connection_id = observation.exchange.connection_id,
            .stream_id = observation.exchange.stream_id,
        };

// Good
    pub fn observeProxy(store: *Store, observation: ProxyObservation) bool {
        if (observation.provider == .unknown) {
            return false;
        }

        var record = switch (observation.phase) {
            .request_started => store.ensure(observation.identity) orelse return false,
            .response_activity, .response_finished, .request_failed => store.find(observation.identity.key) orelse return false,
        };

        const request: ProxyRequest = .{
            .protocol = observation.exchange.protocol,
            .connection_id = observation.exchange.connection_id,
            .stream_id = observation.exchange.stream_id,
        };
```

- Always put single If statements inside brackets

```zig
// Bad
        if (observation.provider == .unknown) return false;

// Good
        if (observation.provider == .unknown) {
            return false;
        }
```

- Do not clamp parameter's list. A function could have at most 3 parameters. More is a smell and
  needs to get worked around
