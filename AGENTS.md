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
- An innovative and modern terminal UI and GUI terminal emulator focused on user awareness.

## Why is telar special ?

- Unlike tmux, it does not settle for being only a multiplexer.
- Like tmux, it is heavily customizable.
- Top notch sidebar, like T3 Code (<https://github.com/pingdotgg/t3code>)

## Architecture

Two processes. The split decides almost everything else, so get it right before
you add anything that crosses it.

### The runtime

One long-lived per SSH account. It owns everything that has to survive the
UI dying: child processes and their ptys, one `vt.Terminal` per pane, what each
agent is currently doing, and the history.

A user closes their laptop lid, the client goes away, and the agents keep
working. That is the whole reason the runtime is separate, and it is the test
for whether a piece of state belongs here. Ask what happens to it when the
window is closed. If the answer is "the session is ruined", it belongs to the runtime.

### The client

It owns what only makes sense while somebody is looking: layout, which pane is
focused, hover, scroll position, selection, what a modal is covering. All of it
is disposable, because the runtime can rebuild everything that matters.

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
- client means the window (GUI) or the headless client connected to telar's runtime.

## Behaviors you follow

- Strive to test only what is being changed. Full test suite are expensive,
  leave them for when a change could affect many flows

- Do not include features that will only work on my local environment. Every
  feature must be thought in the context of a generic user, not just on my
  current environment. My current environment can be used as guideline and
  playground for testing if an approach works, but there should not be any
  hardcoded functionality that just works on my local environment.

## Commit style

When writing commit messages, descriptions or PRs:

- Do not add a footnote with model signature:

```
// BAD
Co-Authored-By: <Model>
```

## Code Style

Before adding, splitting, moving or importing Zig types, apply
[`docs/zig-source-layout.md`](docs/zig-source-layout.md): a public struct is an
implicit PascalCase file; a helper type used by one file stays private in it;
procedures live in snake_case files named after their flow; generic families
are `GenericName.zig` with one public `Type` constructor.

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

- Add comments only on non-trivial and behavior rich methods.
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

- A function takes at most 5 parameters; `zig build codestyle` enforces it. Never pack
  parameters into a context struct that holds a pointer to its owner to stay under the
  limit. A sixth parameter means the function does too much.

- DO NOT INLINE IMPORT calls:

```zig
// Bad
const a: @import("path/to/type/A") = .{};
const b = @import("path/to/some/module").foo();

// Good
const A = @import("path/to/type/A");
const module = @import("path/to/some/module");

const a: A = .{}
const b = module.foo();
```

- DO NOT USE MAGIC CONSTANTS, always replace them with enums

```zig

// BAD
const step: f64 = 3;

// GOOD
const step: Step = Step.start;

```

- Methods of a type (tables and other structs) name their receiver "self":

```zig
const Spring = @This()

// BAD
pub fn speed(spring: *const Spring) ...

// Good
pub fn speed(self: *const Spring) ...
```

- OBJECTS AND FUNCTIONS USING OBJECTS SHOULD HAVE THEIR LAST FIELD ENDING IN COLON

```zig
// BAD
const a: SomeType = .{.a = 1, .b = 2};
const bar = foo(.{ .a = 1, .b = 2});
const b = foo(x, .{ .a = 1, .b = 2});
const c = foo(x, .{
  .a = 1,
  .b = 2
});

// GOOD

const a: SomeType = .{
  .a = 1,
  .b = 2,
};

const bar = foo(.{
  .a = 1,
  .b = 2,
});

const b = foo(
  x,
  .{
    .a = 1,
    .b = 2,
  },
);
```

- ADD colon after last function call parameter only if params > 2 or if params are using an object like rule before
