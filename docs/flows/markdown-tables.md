# Markdown tables in agent messages

The native GUI renders a message header followed by a matching pipe delimiter
row as a table. `ThreadMessage` and `ThreadActivity` already pass assistant text
through `MessageText`; `MessageBlocks` now groups table rows before layout.
No new runtime event or protocol message is needed. The runtime's agent-thread
snapshot remains the source of message text, including the original Markdown.

The GUI owns all table geometry. `MessageTable` borrows source slices during
synchronous preparation, and `MessageTablePaint` distributes measured column
widths within the message bounds. `MessageTableRowPaint` measures wrapped cells
before drawing their background, borders and text. The tallest cell determines
the row height. Measurement and painting use the same flow, fonts and widths.

`MessageTextFlow` supplies inline styles, grapheme wrapping, source-based link
targets and selection geometry. Left, center and right alignment apply to each
wrapped line. Escaped pipes remain part of their cell, including inside inline
code. Table selection produces tab-separated text; the response copy action
continues to return the untouched Markdown.

## Bounds and recovery

- The parser and column layout use fixed storage for at most 32 columns and
  retain no snapshot slices across frames. Work is linear in the bounded
  message source, with a fixed number of parsing and measurement passes.
- A row retains 256 visible line widths per column in stack storage. Lines
  beyond this alignment quota use left alignment and keep all text available.
- Offscreen rows measure their height but publish no quads or link targets.
  Visible cells clip ink and interactive geometry to their column and viewport.
- Incomplete or mismatched delimiters remain prose until a snapshot contains
  a valid table. Literal user messages and fenced code bypass table parsing.
- Empty/missing body cells occupy their column; extra body cells are ignored.
  More than 32 header columns falls back to ordinary text.
- Resizing recomputes widths and wrapping. Closing the GUI discards its table
  geometry; reconnecting renders the same runtime snapshot again.

## Verification

`zig build test-gui` covers parsing, streaming prefixes, malformed delimiters,
escaped pipes, CRLF, literal/fenced isolation, Unicode, numeric alignment,
wrapped-line alignment, measured versus painted height, clipping, offscreen
budgets, link identities, native drag-and-copy, and allocation-free warm layout.

`tools/gui_agent_messages.py` accepts `--response-file` for native visual checks.
The price comparison from the reported screenshot was exercised with five
data rows, long Spanish headers, currency symbols and bold results. The harness
also checks response copying and reconnecting to the surviving provider.
