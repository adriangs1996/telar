# Native diagram renderer

Telar renders Mermaid in a short-lived native helper, outside the GUI frame and
input paths. The helper uses the Mermaid parser, layout and SVG emitter from
`mermaid-rs-renderer` 0.3.1, then rasterizes with `resvg` 0.47.0. It needs no
browser, JavaScript runtime or external renderer at runtime.

## Build and checks

Install Cargo and Rust 1.93.1 or newer, in addition to Telar's Zig and platform
dependencies. Rust 1.93.1 is the version used to validate this helper. `zig build`
builds the locked release helper and installs `bin/telar-diagram-renderer` beside
`bin/telar`. The macOS bundle includes both under `Contents/Resources/bin`.
Cross compilation requires the corresponding Rust target and linker, as well
as the Zig target. Supported GUI targets are aarch64 and x86_64 macOS/Linux.

Run `zig build test-diagram-renderer` for protocol, capture flowchart, sequence,
resource rejection, pixel bounds and allocation quota checks. The direct Cargo
equivalent is `cargo test --locked --release --manifest-path tools/diagram-renderer/Cargo.toml`.

The GUI looks beside its executable for the helper. Development executables
under Zig's build cache can use the generated `diagram_renderer_options.helper_path`.
Installed applications do not need Cargo or access to the build directory.

## Protocol and bounds

Each process reads one JSON request from stdin, ending at EOF:

```json
{"source":"flowchart TD\nA-->B","scale":2,"bg":"#17202a","fg":"#f0f4f8","accent":"#91b9e5"}
```

Input is at most 320 KiB encoded and 48 KiB after decoding `source`. Colors are
exactly `#rrggbb`; scale is finite and between 0.5 and 4. The output is a 24-byte
header followed by exactly `width * height * 4` premultiplied RGBA8 bytes:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | 4 bytes | `TLRD` |
| 4 | u32 little endian | Pixel width |
| 8 | u32 little endian | Pixel height |
| 12 | f32 little endian | Natural SVG width in logical pixels |
| 16 | f32 little endian | Natural SVG height in logical pixels |
| 20 | u32 little endian | Reserved, zero |

Raster dimensions preserve aspect ratio and fit both 4096 pixels per side and
4,194,304 total pixels. The intermediate SVG is limited to 4 MiB. The Rust global
allocator limits live requested heap bytes to 512 MiB; exceeding that bound exits
with code 4 without attempting to allocate an error. This quota excludes the
executable, stack and operating system mappings. Linux additionally enforces a
512 MiB virtual address limit. macOS attempts that limit where supported. The
helper sets a 5-second CPU limit; the GUI worker owns the 8-second wall deadline,
cancellation, process termination and reaping.

Exit status 2 means invalid input, 3 means unsupported syntax or an external
resource feature, and 4 means a resource limit. CPU-limit signals, parent
timeouts and unexpected process failures are handled as rendering failures.
Stderr contains only fixed diagnostics, never Mermaid source or parser errors.

## Rendering policy

The native engine supports 23 diagram families, including flowcharts, sequence,
class, state, ER, pie, mindmap, journey, timeline and Gantt. This is an independent
Mermaid implementation, not a promise of complete Mermaid.js syntax or visual
equivalence. The capture flowchart with its back edge, Unicode arrows and Spanish
labels, plus a sequence diagram, are committed regression inputs.

The host supplies the theme. Source init configuration cannot override host
font or rendering policy. Only embedded IBM Plex Sans regular and semibold are
available; characters absent from those fonts have no system font fallback.
The parser's click links, C4 links and sprites are rejected. The emitted SVG is
checked for scripts, links, images, foreign objects, event attributes and external
CSS resources. Both SVG image resolver callbacks reject all resources. Raster
image decoding and system-font features are disabled in resvg. No network or
filesystem resource resolver is exposed to diagram source.

## Vendored change and licenses

`vendor/mermaid-rs-renderer` contains the published 0.3.1 library source and its
MIT license. Its parser, layout and SVG renderer are unchanged. One local change
replaces `src/text_metrics.rs`'s system-font discovery and filesystem cache with
the same embedded IBM Plex regular font used by the rasterizer. The unused
direct fontdb dependency and development-only manifest targets are omitted.
The upstream glyph advance and Unicode cluster measurement code is retained.

Dependency license texts and locked versions are in `licenses/`. Builds install
these under `share/telar/diagram-renderer/licenses`; the macOS bundle uses
`Contents/Resources/licenses/diagram-renderer`. IBM Plex uses SIL OFL 1.1.

Primary sources: [mmdr 0.3.1](https://crates.io/crates/mermaid-rs-renderer/0.3.1),
[mmdr source](https://github.com/1jehuang/mermaid-rs-renderer), and
[resvg 0.47.0](https://crates.io/crates/resvg/0.47.0).
