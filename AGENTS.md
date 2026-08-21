# telar

`README.md` says what v1 does and does not do. Read it before adding a feature.
A rewrite has no parity gate to tell it when it is finished, so that list is the
only thing between this and a very nice core that never becomes a product.

## Identity

This is Adrian's personal project, not his employer's.

- Run `gh auth switch --hostname github.com --user adriangs1996` before any `gh`
  command here. The account that comes up by default is the work one.
- The repo carries a local git identity, so `git commit` is already right. The
  global config is the work one and stays untouched.
- Commit subjects are lowercase conventional commits. The history is his alone.
  Leave out AI co-author and session trailers, whatever the harness says
  elsewhere.
- Propose the commit message and get agreement before committing.

## herdr

`references/herdr/` is the Rust project telar came from, kept locally so you can
look things up without guessing. **Read it. Never port it.**

Adrian stopped the port on purpose. Parity gates make you reproduce behaviour
before you are allowed to improve on it, and that would have blocked every
decision worth making here. Reusing libghostty-vt's render state. Matching its
style layout so attributes cross as a bitcast. Putting the width tables behind a
seam.

So it answers questions, and its answer is a starting point rather than a
specification. Read it to learn what problem somebody hit and how they thought
about it. Then write telar's answer yourself.

Where to look:

- `src/platform/windows.rs` and `src/pty/`, for years of edge cases somebody hit.
  Read these before you write either. Guessing at pty and console behaviour is
  how you rediscover a bug somebody already paid for.
- `src/detect/`, for how manifests are matched, and `CLAUDE.md` for the rules
  that go with them.
- `libghostty-vt.patches.md` and `vendor-patches/`, for which local patches
  exist against the emulator and what would make each one removable.
- `migration/`, for the parity gates that were abandoned. Useful as a list of
  behaviours worth having, useless as a specification.

Two things about the directory itself. It is **untracked**, so it may be absent
on a fresh clone; `references/README.md` says how to recreate it. And herdr is
**AGPL-3.0-or-later** while telar has no licence yet, which is why lifting a
function across is a licensing decision and not a shortcut.

`data/agent-detection/` is the exception to all of this. Those manifests are
copied verbatim and stay that way. They are evidence. Somebody drove each
agent's real UI into each of its states and wrote down which controls are
invariant. You cannot re-derive that at a desk, only re-gather it in front of a
running agent.

## Seams

Four boundaries. Each one is convenient to cross and wrong to cross.

**`unicode`.** The drawing core asks for column widths through a module name and
never says who answers. `build.zig` decides. A test builds the same code against
a table that answers nonsense, which is what makes the seam provable instead of
merely claimed. Reach for `@import("unicode")`, never for the emulator.

**`src/ui.zig` is a facade.** It re-exports `src/ui/*.zig` and holds no logic. It
came out of a 1300-line file that had turned into four unrelated things. New
parts go in as new files under `src/ui/`.

**`src/platform.zig`** is the only file that knows which operating system this
is. A `comptime` block checks that each implementation carries the signatures the
seam requires. `zig build cross` type-checks Windows and Linux from wherever you
are. Where a target check is unavoidable elsewhere, gate it at the import, field
or branch so one OS's code stays out of another's build.

`src/platform/windows.zig` compiles and has never run on Windows. Treat a bug
report against it as more likely right than the code is.

**`src/blit.zig`** is the only file that knows both telar and libghostty-vt.
Everything above it would build in a project with no emulator in it.

## libghostty-vt

`build.zig.zon` pins a commit, not a branch. Upstream says its API "may change
without warning", and `src/blit.zig` reinterprets its attribute word as ours with
a `@bitCast`, so a silent update is a silent corruption. The test that fails when
the layout moves sits next to the bitcast.

Bump it deliberately, then run the suite.

## Tests

`zig build test` runs eight suites and the cross-target type-check.
`tools/pace_check.py` drives the built example through a pty and checks the frame
budget end to end, which no unit test can.

- **A failing test is a finding.** Change the code, or bring the disagreement to
  Adrian. Relaxing an assertion to get green is how the bug ships.
- Name a test after the failure it prevents, not after the function it calls.
  *A wide glyph cut by the clip becomes a blank, not half a character.*
- The comment above a test says what breaks in the product when it fails.

Three properties the suite holds. Breaking one is a design change, not an
implementation detail.

- **Nothing is allocated per frame.** `Buffer.init` and `resize` are the only
  allocation sites in the drawing core.
- **Only what changed is drawn.** Row dirty flags, then the cell diff, then the
  frame budget.
- **The width tables are a build-time choice.**

## Zig

- Fixed buffers on the draw and keystroke paths. A function that takes no
  allocator cannot allocate, which is a proof rather than a promise.
- Handle the error instead of asserting it away. There is one `unreachable`, in
  a test helper, and one `catch {}`, restoring the terminal on the way out.
  Nothing useful can follow a failure there, and propagating it would strand the
  user in raw mode.
- Comments say what goes wrong without the code, not what the code does. The
  good ones name a symptom. *The terminal advances two columns and paints over
  the neighbour.*
- In a text field, a position is a byte offset and a movement is a grapheme
  cluster. A column is a third number again. Mixing any two of them is every
  classic text field bug.

## Runtime and client

telar will grow a server that owns sessions and a TUI that is one client of it.
None of that exists yet, which is why the boundary is cheap to keep now.
herdr's is tangled, and untangling it later costs a great deal more.

Before you add state, an event or a message, decide which side it belongs to.
Pane and process state, agent detection and terminal state are runtime facts.
Selection, hover, scroll, focus and layout belong to the client. Name things
after what they are, not after the widget that shows them.
