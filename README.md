# telar

A terminal runtime for coding agents, and the UI core it is built on.

*Telar* is Spanish for loom, the machine that holds many threads under tension
and weaves them into one surface. A **hilo** is one agent session, which is a
thread of execution and a thread of conversation at the same time. The **trama**
is how they are laid out on screen.

Written in Zig 0.16. Very early.

## What this is not

telar began as a port of [herdr](https://github.com/ogulcancelik/herdr) to Zig,
and stopped being one on purpose.

A port has to reproduce behaviour before it is allowed to improve on it, and
that ruled out every decision worth making here: reusing libghostty-vt's render
state instead of re-deriving it, matching its style layout bit for bit so a
pane's attributes cross as a `@bitCast`, putting the width tables behind a
module seam. The parity gates would have forbidden all three.

So nothing comes across. herdr is AGPL-3.0-or-later and telar is MIT, which
settles the question that judgement alone would have left open: reading it to
learn what problem somebody hit is fine, and lifting a line is a licence
violation.

The detection manifests were the one thing worth copying, since they are
gathered evidence rather than logic. They are gone too. telar will generate its
own by watching agents run, which costs more up front and buys a better model
than herdr's, where the maintainer tunes every manifest by hand and ships it.

## Scope

A rewrite has no definition of done, which is how a rewrite becomes a very nice
core that never turns into a product.

### v1 does

- Run agents in panes, with a real terminal emulator behind each one
- The sidebar: sessions, their state, their origin
- Mouse and keyboard throughout, because this is a mouse-first TUI
- Agent detection, from manifests telar generates by watching an agent run
- Select and copy, including from a pane, unwrapped

### v1 does not

- A release channel, an updater, an installer, or a website
- A plugin system
- Anything that exists in herdr only because herdr shipped it

## The core

Everything under `src/` is portable and testable without a terminal, except the
two files whose whole job is not to be.

| | |
|---|---|
| `ui` | geometry, cells, the buffer, clipping, layered hit testing, focus |
| `term` | the diff, escape sequences, the input parser, OSC 52 |
| `pace` | when to draw, and what to fold away first |
| `edit` | a text field: byte offsets, cluster movements, selection |
| `select` | dragging text off the screen so it can be copied |
| `blit` | the adapter to libghostty-vt, and the only file that knows both halves |
| `platform` | the only file that knows which operating system this is |

Three properties it holds.

**Nothing is allocated per frame.** The buffer allocates when the window resizes
and never again, and the render state upstream retains its own. A test runs
sixty-four frames behind an allocator that panics on the first allocation.

**Only what changed is drawn.** The emulator says which rows moved, the diff
says which cells did, and the pacer bounds how often either is asked. What the
pacer folds away depends on the kind of event. Three hundred pointer moves
collapse to the last position. Three hundred keystrokes all arrive, because each
one carries something the next does not. Neither turns into three hundred
frames, which is the whole point.

**The width tables are a build-time choice.** `ui` imports `unicode` by module
name and never says who answers. The default is the emulator that will render
the agents' own output, since two disagreeing width tables produce a UI that
slides one column at a time. A build with no emulator in it can swap the module,
and a test proves the seam by swapping it for one that answers nonsense.

## Building

Zig 0.16.

```
zig build test      # the suite, plus a type-check for Windows and Linux
zig build sidebar   # the example
```

`AGENTS.md` has the conventions, the seams worth not crossing, and what to read
herdr for.

## Licence

MIT. See `LICENSE`.

telar carries no code from any copyleft project, which is what keeps that
possible. `references/` explains the one place the question comes up.
