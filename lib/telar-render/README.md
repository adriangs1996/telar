# telar-render

Renderers turn content into one **document** model that a client draws
natively. Markdown is the first renderer. Rendering runs in the short-lived
`telar render` command, never in the runtime or the GUI. Those only decode a
bounded, validated binary encoding, so untrusted source never reaches a
parser in a long-lived process.

C++23 modules:

| Module | What it does |
| --- | --- |
| `telar.render.document` | The document model, its binary encoding and decoder, and the OSC that carries it |
| `telar.render.markdown` | GitHub-flavoured Markdown to a document, through vendored [MD4C 0.6.0](../../vendor/md4c-0.6.0/TELAR-VENDOR.md) |
| `telar.render.terminal` | A document as SGR-styled text wrapped to a width, for terminals without native support |

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-render" "${CMAKE_CURRENT_BINARY_DIR}/telar-render")
target_link_libraries(your_target PRIVATE telar::render)
```

```cpp
import telar.render.markdown;

telar::render::Document<Memory> document{memory};
if (telar::render::markdown::render(source, document) == telar::render::markdown::Error::none) {
  telar::render::appendSequence(document, output); // ESC ] 7780;begin;<base64> ESC \
  telar::render::terminal::render(document, width, output);
  telar::render::appendEnd(output);                 // ESC ] 7780;end ESC \
}
```

## Document model

A document is a flat list of leaf **blocks** in reading order: paragraph,
heading, code, rule, table and raw HTML. Containers are not nodes. A block
quote, a list item or a GitHub alert becomes decoration on the leaves inside
it:

- `quote` and `list` hold the nesting depth.
- `marker` (bullet, number, task, footnote) is set only on an item's first leaf.
- `callout` is the innermost alert; `opens_callout` marks the alert's first leaf.
- `tight` marks blocks of a tight list, which have no gap before them.

A client lays the blocks out one after another without walking a tree.

Paragraphs and headings hold **runs**: text with one style (strong, emphasis,
code, strike, link, image, math, inline HTML, superscript) and an optional
target. A hard break is a `'\n'` inside a run. A soft break is a space. Tables
hold **cells** row by row. The first row is the header, and every row has
`columns` cells. All text lives in one UTF-8 pool, addressed by byte spans.

Links and images are data: renderers never fetch an image or resolve a link,
and raw HTML is shown verbatim. The window opens a link only when the user
clicks it, and only an http, https or mailto link.

## Encoding

Little endian, fixed-size records, version 1:

| Part | Layout |
| --- | --- |
| Header, 24 bytes | `TRDC`, u16 version, u16 0, u32 blocks, u32 cells, u32 runs, u32 text bytes |
| Block, 32 bytes | u8 kind, level, quote, list, marker, callout, flags, 0; u16 columns, u16 0; u32 number, first, count; u32 info offset, info size |
| Cell, 12 bytes | u32 first run, run count; u8 align; 3 zero bytes |
| Run, 20 bytes | u32 text offset, size; u32 target offset, size; u16 style, u16 0 |
| Text | UTF-8 |

`decode` assumes any program in a pane wrote its input. It rejects the input
unless all of the following hold:

- the record counts add up to the exact size
- every enumeration and flag is known
- reserved bytes are zero
- every range is in bounds and every span starts and ends on a UTF-8 character
- the text is valid UTF-8

On failure the document is left empty.

## The sequence

A program hands its pane a document with one OSC, `ESC ] 7780 ; begin ;`
followed by the base64 of the encoding and `ESC \`. The OSC carries a
binary encoding through a channel that is not 8-bit clean: the runtime's
parser drops bytes below `0x20` inside an OSC, and BEL and ESC end it. Its
8 MiB buffer for one OSC bounds the document to 6000 KiB.

- **Inline**, on the primary screen: the `begin` OSC opens a zone at the
  cursor's row; the styled text follows; `ESC ] 7780 ; end ESC \` closes it.
  A client that can draw documents shows the document in place of those
  rows, in the rows it takes; any other client, `telar pane read`, the
  history and terminals other than Telar show the text.
- **Pager**, on the alternate screen: the `begin` OSC alone covers the
  pane until the program leaves that screen.

## From a pane to the window

1. `telar render markdown` writes the sequences: around its styled text, or
   after entering the alternate screen with `--pager`.
2. The runtime's control engine buffers the OSC whole: `classification.hpp`
   marks OSC 7780 non-streamable and `Engine::osc` takes it. Ghostty never
   sees it, and the media worker streams past it without buffering.
3. Inline, the runtime anchors the zone's first and end rows with ghostty
   tracked grid refs, which follow the rows through reflow and are lost when
   the scrollback drops them. It keeps the last 8 documents per pane, 16 MiB
   in all, and drops the oldest past either. As a pager, it keeps the
   document until the pane returns to the primary screen.
4. Each attached client receives `PaneDocument` messages in 64 KiB parts,
   on the lowest-priority pane lane. Document 0 is the pager's. Each inline
   document comes with the stable rows it stands for. After a reflow the
   client gets only the new rows, not the bytes again.
5. The GUI assembles and decodes each document.
   - **Inline**: `InlineDocuments.qml` lays the document out and measures
     it in rows. The pane's `FoldMap` then shows the zone's rows in that
     many display rows, so the document takes exactly the room it needs.
     The text's cells under it are not painted.
   - **Pager**: `DocumentView.qml` covers the pane. Its scroll keys (j/k,
     the arrows, space/b, Page Up/Down, Ctrl-D/U and g/G) and the wheel move
     the document, and every other key reaches the program.

## Limits

| Limit | Value | Bounds |
| --- | --- | --- |
| `render.max_markdown_bytes` | 4 MiB | Markdown source read by the renderer |
| `render.max_document_bytes` | 6000 KiB | Encoded document written or accepted |
| `render.max_pane_documents` | 8 | Inline documents a runtime keeps per pane |
| `render.max_pane_document_bytes` | 16 MiB | Their encoded bytes in all |
| `render.max_nesting` | 32 | Quote and list depth recorded; deeper blocks keep this depth |

## Standalone checks

```sh
tools/cpp configure render
tools/cpp build render
tools/cpp test render
```

The tests cover the Markdown structure, round trips and rejection of corrupt
encodings. A mutation pass corrupts the encoding at random and checks that
decoding never crashes or accepts out-of-range data. They also cover repair of
invalid UTF-8, the limits, the OSC framing, and that terminal output contains
only SGR escapes and fits its width.
