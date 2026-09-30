# Change review prototype

Branch: `feat/change-review-prototype`.

This first experiment adds Tree-sitter syntax colors to the existing native diff
viewer. Run `zig build run-widget` to inspect the sample in
`examples/change-review.diff`. Press **T** to cycle through Telar's built-in
themes and scroll to compare languages. Resize the window to inspect wrapping.
The standalone runner deliberately uses the sample rather than live file edits.

The same painter renders existing agent file-change cards and fenced
`diff`/`patch` blocks. Hooks, revision publication and review decisions are not
implemented by this experiment.

The optional [live experiment](change-review-live.md) now connects this same
widget to one real agent session through an isolated coordinator. Default runs
still use the bundled fixtures. Production pane hooks and runtime integration
remain outside the experiment.

## Interactive experiment

`run-widget` now embeds `src/gui/experiments/review/Widget.zig`. The application
does not import that experiment. It indexes two immutable fixtures before opening
the window and retains syntax roles for both; navigating never reparses source.
The existing diff painter accepts optional synchronous annotations for line
selection and inline comments. Ordinary application callers leave them absent.

- Choose a file in the sidebar; Tab and Enter also select a file.
- Use arrows or `j`/`k` to move between lines. `v` (or `V`) enters visual line
  selection: motions extend or shrink the range, and `c` comments on that range.
  The footer shows VISUAL LINE and the selected line count. Escape or another
  `v` returns to a single line. Shift also extends a range.
  Visual selection stops at the hunk boundary and skips the opposite diff side;
  it never crosses files or editions. Deleted lines can receive comments.
- `n`/`p` or Previous/Next traverse hunks and continue into adjacent files.
- Click a line number to select it, or Shift-click to extend. The gutter `+`,
  toolbar Comment button and `c` open the inline editor.
- Drag code to select text, then Cmd/Ctrl+C copies it without diff markers.
- Enter inserts a newline. Cmd/Ctrl+Enter saves locally; Escape first cancels
  preedit, then folds the editor without discarding its draft. Navigation letters
  remain ordinary text while the editor owns focus.
- Saved comments can be opened, edited, folded or deleted. Comments show their
  edition, before/after side and line range. Long comments expand into the flow.
- Mark reviewed records inspection of that file in that edition.
- Simulate next edit announces edition 2 without navigating away. Open edition 2
  switches snapshots; Back to edition 1 exposes the original comments and drafts.
  Changed files start unreviewed in the new edition; unchanged files inherit the
  reviewed state at the moment the new edition is announced.

All review state is local to this window and disappears on close. There is no
agent communication, approval effect, Git mutation or durable review storage.
The next integration must transfer durable comments and edition identity to the
runtime; the experiment intentionally exercises their interaction first.

Bounds are two revisions, 32 files and 1,024 numbered rows per revision, 32 comments,
and 2,048 UTF-8 bytes per comment. Capacity errors preserve existing text. The
shared native field supplies grapheme editing, multiline geometry and IME preedit.
Clipboard reads and cuts retain destination identity, selection and edit revision;
late completion cannot modify a replacement editor or a changed draft.
The delivered widget registry remains input authority during GPU flights. Changing
file, edition or editor advances the owner generation; stale targeted events are
rejected. Escape uses the dispatcher's existing editor-key path so cancellation
does not first remove focus from the editor.

`zig build test-widget` includes model and native-runner integration tests for
anchor boundaries, draft retention, edition replacement, Unicode text, preedit,
capacity, stale editor events, clipboard races, code copying and presentation
ownership. Native visual checks exercise writing and saving a multiline comment,
switching editions, and reopening the original review.

## Theme contract

Syntax roles resolve through `Theme.syntaxStyle` at paint time. Shade now uses
Adrian's Osaka Jade syntax colors, read from his Neovim theme and its Vesper
highlight definitions. Source syntax has its own roles within the Telar theme;
it no longer borrows Shade's UI colors indiscriminately.

| Syntax role | Shade color/style |
| --- | --- |
| Ordinary text | `#d1d1cf` |
| Keywords, operators, punctuation | `#a0a0a0` |
| Functions and Zig builtins | `#a8c98c` |
| Types and constants | `#c3cea0` |
| Strings | `#91b99a` |
| Numbers and builtin constants | `#e6b99d` |
| Comments | `#304a39` |
| Parameters | `#add0c5`, italic |
| Properties | `#bbc8b5` |
| Namespaces | `#c4b3c5` |

`theme.syntax` accepts per-role colors or `{ fg, italic, bold }` overrides.
Profiles and appearance variants inherit them through the existing theme path.
The other presets still derive unspecified syntax styles from their palettes.
ANSI and UI colors remain independent. Additions and deletions retain their
background tints and gutter markers without replacing syntax ink.

Upstream grammar queries classify functions, types, parameters and other syntax.
Available categories depend on the language's query. This is syntax highlighting,
not an LSP: it does not reproduce every semantic classification from Neovim.

## Ownership and rendering

`telar-client/syntax` defines symbolic roles and extension detection. It has no
parser or native dependency. The native viewer links the vendored Rust
`tree-sitter-highlight` library and upstream grammars through a small C ABI.
The library returns UTF-8 byte ranges and capture names; Telar maps those names
to theme roles. See `tools/syntax-highlighter/README.md` for build details.

The review panel (`gui/change_review/Panel`) schedules one observation task
through the existing inbox. It owns an immutable copy of the patch in an
inactive slot. `DiffHighlighter` reconstructs before/after hunk sources using
the existing diff iterator, parses them separately, and projects captured byte
ranges back onto the patch. File and hunk boundaries reset source context. No
file is reopened to color an older patch.

The panel retains two patch slots, each with one role per byte, reserved when
the window starts. Painting does not parse or allocate; it borrows the visible
slot's roles. Worker completion is adopted after inbox notification, and
generations reject stale results after slot replacement. Shutdown uses the
inbox's existing producer join before releasing GUI state. Theme changes
recolor existing roles without reparsing. Selection and grapheme geometry
retain their existing source offsets.

Each parse has a 100 ms cancellation deadline; each patch admits at most 1,024
source fragments and stops admitting fragments after one second. A patch that
reaches either keeps the roles already highlighted, leaves the rest plain and
reports the limit. Grammar setup is once per process on the worker. These are
source, retention and work limits, not a hard allocator quota for Tree-sitter.
Failed, oversized or unknown content stays readable in the plain syntax color.
The standalone sample prepares its tokens before opening the window; the real
GUI uses the asynchronous panel job.

## Limits that the full review design must address

The bundled grammars cover Zig, Ruby, Python, JavaScript/JSX, TypeScript/TSX,
JSON, Rust, Bash, Go, C#, Java, Kotlin, Swift, C, C++ and Objective-C.
Adding a language means bundling its grammar and highlight
query and registering its extension; Telar does not implement its lexer.
Unknown extensions remain literal. This experiment integrates the native viewer;
a future TUI review surface can reuse the roles and the library contract.

A patch can omit the start of a multiline string or comment. Resetting at hunk
boundaries avoids carrying state across missing source, but cannot recover that
missing context. The full review feature must highlight complete immutable
before/after contents and project those spans onto the diff. It must not fetch
the current working file to color an older revision.

Before accepting the broader review feature, require complete-source highlighting
for the supported languages, theme and override coverage, independent old/new
parsing, preserved selection, and bounded work outside the input/frame path.

## Verification

`zig build test-client test-gui test-widget build-widget test-syntax-highlighter codestyle`
checks grammar captures, independent diff versions, highlighting stopped at its
limits, failure handling, palette changes, Unicode geometry, viewport
clipping, warm drawing without allocations and the standalone runner.
`zig build check-client-boundaries` checks the shared-client dependency boundary.
