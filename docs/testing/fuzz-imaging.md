# Imaging fuzz targets

Zig's built-in fuzzer, `std.testing.fuzz`, drives `imaging.png.decode` and
`imaging.ico.decode` from two roots under `lib/imaging`:

| File | Holds |
| --- | --- |
| `png_fuzz_test.zig` | the PNG root: generated, rewritten, mutated and raw-chunk PNGs |
| `ico_fuzz_test.zig` | the ICO root: generated, mutated and raw ICO files |
| `png_fuzz_seed.zig` | Smith seed encoding and the release and budget checks both roots share |
| `png_fuzz_file.zig` | the PNG byte layout, chunk writing and zero-sample PNGs both roots write |
| `BoundedTestAllocator.zig` | the test-only allocator that enforces the allocation budget |

`build/fuzz_imaging.zig` registers them. No other file imports them, and
`lib/imaging/root.zig` exports none of them. The inputs are small synthetic
images built in memory; the only file the targets read is the versioned
`lib/imaging/testdata/telar.ico`, as one raw ICO seed.

## Build steps

`build/tests.zig` registers the steps through `fuzz_imaging.add`:

| Step | Runs |
| --- | --- |
| `test-fuzz-imaging` | the `lib-imaging` tests and both fuzz roots |
| `test-fuzz-imaging-png` | the PNG fuzz root alone |
| `test-fuzz-imaging-ico` | the ICO fuzz root alone |

The roots stay out of `test-libraries`, `test`, `check` and the coverage
build. They are built like the handshake fuzz target of commit d519fb1d,
whose message records why: LLVM, and no error return traces in the fuzz root
only. Runtime safety stays on, and the library keeps its own settings.

## Commands

```sh
# Replay both corpora and run the directed tests, without fuzzing.
zig build test-fuzz-imaging -Dgui=false -j1

# Fuzz one target for a bounded number of runs; the limit takes K, M and G.
zig build test-fuzz-imaging-png -Dgui=false -j1 --fuzz=10K
zig build test-fuzz-imaging-ico -Dgui=false -j1 --fuzz=10K
```

`zig build test-fuzz-imaging --fuzz=10K` starts one fuzzer per target at the
same time, so a campaign that has to share the machine uses the per-target
steps one after the other.

The run ends with a report of runs, unique runs and covered PCs. The counts
accumulate across runs while `.zig-cache` is kept. They cover the whole test
executable: the test runner, std, the oracles, the Ghostty Wuffs wrapper and
`lib/imaging`.

## Reading a failure

A found failure does not change the exit status of `zig build` in Zig 0.16.0.
Read the output instead. A broken property panics with
`PNG property failed: ...` or `ICO property failed: ...`, as the handshake
target does, and the runner reports the test as terminated by a signal with
`input saved to '.zig-cache/f/crash'`.

The saved file is in the form the fuzz test reads, so it can join the corpus
as it is:

```zig
test "fuzz png decoding" {
    try std.testing.fuzz(
        {},
        decodeFuzzedPng,
        .{
            .corpus = &(png_corpus ++ [_][]const u8{@embedFile("png_fuzz_found_crash")}),
        },
    );
}
```

A plain `zig build test-fuzz-imaging-png` then replays it.

Once, the runner wrote an empty `crash` file even though the fuzzer's input
map `.zig-cache/f/in<N>` still held the crashing input. That input starts
after a 20-byte header whose little-endian u32 at offset 16 is its length:

```sh
len=$(od -An -tu4 -j16 -N4 .zig-cache/f/in0 | tr -d ' ')
tail -c +21 .zig-cache/f/in0 | head -c "$len" > lib/imaging/ico_fuzz_found_crash
```

## Wuffs C is not instrumented

`--fuzz` rebuilds the whole compilation with `-ffuzz`, and that reaches the
Wuffs C that the `wuffs_c` module compiles. Clang then emits
`__sanitizer_cov_trace_cmp*` and `__sanitizer_cov_trace_switch` calls, which
the Zig 0.16.0 fuzzer runtime does not define, so the link fails. With those
symbols stubbed out, the runtime aborts at start:
`pc counters length and pcs length do not match (47466 != 9859)`. The C
counters land in `__sancov_cntrs`, but Zig's PC table (`__sancov_pcs1`) does
not list them.

The fuzz roots therefore import a copy of the configured `imaging` library.
The copy's `wuffs` imports a copy of `wuffs_c` with `fuzz = false`, and
everything else keeps its configured settings. The shared modules stay as
they are, so telar and the other tests build as before. A `--verbose` build
with `--fuzz` prints the fuzz root's compile command with `-ffuzz` at the
front and `-fno-fuzz -OReleaseFast -I …/release/c … -Mwuffs_c=…` for the C.

As a result, the fuzzer gets no coverage feedback from Wuffs and reaches its
code only through the inputs the Zig side builds. The Zig of `lib/imaging` is
instrumented.

The copies share every list of the original modules except the import
table: C macros, include and library paths, rpaths, frameworks and link
objects. That is safe only because the shared modules are fully configured
when the registry runs from `tests.add`, and nothing appends to them
afterwards. A later `addCSourceFile`, `addIncludePath` or `linkFramework` on
either module could reallocate storage the other still points to.

### `-Dcoverage`

`-Dcoverage` sets `fuzz` on every shared library module and, through
`Libraries.addTests`, links the zcov runtime object into it. The `imaging`
copy drops only the inherited `fuzz` setting and still shares the runtime
link object. A flag check with a placeholder runtime path showed no `-ffuzz`
on the fuzz root's compile command. It did not run anything: the build then
failed opening the placeholder object. These steps have not been run under
`-Dcoverage` with a real runtime, so run them without it.

## Two bounds: admission and allocation

**Admission** is what the decoders check in the header before Wuffs
allocates:

- `png.decode` rejects a width or height over `max_side`, or an area over
  `max_pixels`. The PNG root decodes under `fuzz_limits` (64 per side, 1024
  pixels) or under limits set exactly at, or one short of, the generated
  image.
- `ico.decode` inspects at most 64 entries and decodes PNG frames under 256
  per side and 65 536 pixels.

Admission bounds what the header may ask for. It does not measure what a
decode allocates afterwards.

**Allocation** is a hard limit on the bytes one decode holds live.
`BoundedTestAllocator` sits between the oracle's `FailingAllocator` and
`std.testing.allocator`. It refuses any allocation, resize or remap that
would take its live bytes past the budget, before the testing allocator is
asked, so the refused bytes are never reserved. The testing allocator keeps
its leak checks. Every fuzzed decode, every injected allocation failure and
the exhaustive allocation-failure tests run under it. A request that would
exceed the budget is refused and fails the property, even if the decoder
otherwise returns a normal rejection. The oracle requires zero refusals.

| Root | Budget | Measured peak | Sampled images |
| --- | --- | --- | --- |
| PNG | `allocation_budget` = 56 KiB | 56 984 bytes, a 16 x 64 RGBA16 image | a zero-sample PNG in each of the 15 color type and bit depth pairs, interlaced and not, at every width 1 to 64 with the tallest height `fuzz_limits` then admit: 1 920 decodes |
| ICO | `allocation_budget` = 812 KiB | 831 320 bytes, at width 256 | single-entry ICOs holding the same 30 PNG kinds, and a zero DIB, at widths 1, 128, 255 and 256 with height 256: 124 decodes |

Each budget is its measured peak rounded up to 4 KiB. The tests
`the allocation budget sits one rounding above the sampled peak, ...` (PNG)
and `... the sampled frame peaks, ...` (ICO) measure through a limit-free
`BoundedTestAllocator` and require the peak to stay under the budget and
within 4 KiB of it. A change in Wuffs's allocations then fails a test instead
of hiding in a margin. The ICO test also requires the largest peak to come
from width 256.

The samples do not prove that every admitted file stays under the budget,
and nothing here names an exact size for the pixel buffer. The peaks count
the three allocations the Ghostty wrapper makes (decoder state, pixels and
work buffer) as observed, not as derived from Wuffs's code. What protects
the fuzzed decodes is the hard limit, which fails any request that would
exceed it.

The same tests show a request past a limit is refused without being
reserved:

- the PNG test decodes the 16 x 64 RGBA16 image under a limit one byte below
  its peak. The decode answers `OutOfMemory`, the bounded allocator records
  one refusal, and a second limit-free allocator underneath never held as
  much as the peak;
- the ICO test decodes a 256 x 256 DIB, whose pixels are one 262 144-byte
  request, under a limit one byte short. It records one refusal, and the
  allocator underneath never held a byte.

`BoundedTestAllocator.zig` tests the same for plain allocations, resizes and
remaps.

## Generation

### PNG

Each input generates an image in a shape `encodeForTest` writes: RGB or RGBA
at 8 or 16 bits, or an 8-bit palette. Its fields are:

- up to 64 bytes per row, the encoder's filter row, and 1 to 16 rows;
- filter type 0 to 4 for every row;
- fuzzed samples;
- for a palette, 1 to 256 entries, indices reduced into the palette, and an
  optional tRNS no longer than the palette.

The limits are `fuzz_limits`, exactly the image's longer side, one less,
exactly its pixel count, or one less. The input then takes one of four cases:

| Case | File decoded |
| --- | --- |
| `generated` | the encoded file |
| `equivalent` | the same zlib stream split into 1 to 4 IDAT chunks (some may be empty), plus an optional unknown ancillary chunk `fuZz` after IHDR, before the data or after it |
| `mutated` | 1 to 4 of: flip or set a byte, truncate, rewrite an IHDR field with a matching CRC (widths and heights include 0, 2^16, 2^31 and 2^32-1), rewrite a chunk length, break a chunk CRC, drop or duplicate a chunk |
| `raw_chunks` | the signature and valid IHDR followed by up to 8 KiB of fuzzed chunk bytes |

### ICO

Each generated input has one to four payloads:

- 32-bit BITMAPINFOHEADER DIBs up to 40 x 24, with an alpha channel or an
  empty alpha channel and a fuzzed AND mask, padding bits included. Widths
  past 32 give mask rows two words.
- RGBA8 PNGs up to 16 x 16 from `encodeForTest`.

A directory of 1 to 64 entries names them; several entries may share one
payload. A payload may carry one defect:

- an unsupported bit count, BI_BITFIELDS compression or a color table, which
  get the entry skipped;
- wrong planes, a wrong height or a truncated mask, which are invalid;
- a PNG with a broken IHDR CRC.

An entry may carry one defect: a reserved byte, an offset before the
directory or past the end, a size past the end, or a declared width that
differs from the payload, 256 included. The header may be too short, have a
wrong magic, have 0 or more than 64 entries, or be cut inside the directory.
The cell is 0 to 41, 0 to 257, or 2^32-1.

The `mutated` case applies 1 to 4 byte flips, byte sets, truncations or entry
rewrites. A rewrite changes the width, height, reserved byte, size or offset,
and the values include 0 and 2^32-1. The `raw` case decodes up to 32 KiB of
fuzzed bytes.

## Oracles

A decode error is a normal outcome. What fails a property is the wrong error,
wrong pixels, an allocation the contract forbids, a request that would exceed
the allocation budget, or memory not released.

PNG:

- The oracle repeats the checks `decode` makes before Wuffs, in their order:
  signature and length, IHDR length and type, IHDR CRC, zero dimensions, then
  the limits in 64-bit arithmetic. When they reject, the error must be exactly
  that one and nothing is allocated.
- Past those checks, only `InvalidPngData` may reject. `PngTooLarge` and
  `OutOfMemory` without an injected failure are failures.
- A `generated` or `equivalent` file within its limits must decode. Its pixels
  must equal a reference computed from the samples without the decoder: the
  high byte of 16-bit samples, opaque RGB, and palette alpha from tRNS or
  opaque.
- Every image has the IHDR's width and height and `width * height * 4` bytes.

ICO:

- The oracle repeats the header checks: length and magic give `NotIco`, a
  count of 0 or more than 64 gives `UnsupportedIco`, and a directory longer
  than the file gives `InvalidIcoData`. None of them allocates.
- For a `generated` file, the oracle computes the outcome from the
  generation decisions, following the decoder's check order: bounds, reserved
  byte, PNG signature, unsupported bitmap, dimensions, planes, length.
  - `InvalidIcoData` if any entry is fatal;
  - `UnsupportedIco` if every entry is skipped;
  - otherwise the entry with the smallest side covering the cell, or failing
    that the largest, the first on ties, whose PNG may reject with
    `InvalidPngData` or a width mismatch with `InvalidIcoData`.

  Pixels must match exactly: DIBs flipped from bottom-up BGRA, with alpha from
  the channel, or from the mask when the whole channel is empty.
- For `mutated` and `raw` files, a rejection must come from the ICO and PNG
  error sets without `OutOfMemory`, and an image must have a size some
  directory entry declares, 1 to 256 per side and four bytes per pixel.

Both targets count every allocation through `std.testing.FailingAllocator`.
After each decode, and after freeing its image once, the allocated and freed
byte counts and the allocation and free counts must match. The bounded
allocator must then hold nothing and record no refusal. These checks panic
inside the fuzz test instead of leaving the leak to the testing allocator's
report.

## Allocation failures

- **Fuzzed.** After the clean decode, about a quarter of the inputs decode
  again with one allocation failing, chosen among the ones the clean decode
  made. Decoding is deterministic, so that allocation is reached, and the
  result must be exactly `OutOfMemory` with everything released and nothing
  refused by the budget. No input walks every failure point.
- **Exhaustive.** Directed tests run `std.testing.checkAllAllocationFailures`
  over representative inputs, with the bounded allocator as their backing:
  - PNG: RGBA8 Paeth, RGB16 Average and a palette with tRNS;
  - ICO: a single DIB, a DIB/PNG/DIB directory, and a PNG entry, each at cells
    1, 10 and 32.

  They sit next to the existing ICO test over `telar.ico`.

## Generation bounds

| Constant | Value | Bounds |
| --- | --- | --- |
| PNG `max_row_bytes`, `max_rows` | 64, 16 | generated image size |
| PNG `fuzz_limits` | 64 per side, 1024 pixels | admission of every fuzzed PNG decode |
| PNG `allocation_budget` | 56 KiB | live bytes of each fuzzed PNG decode |
| PNG `file_capacity` | 8 KiB | generated, rewritten, mutated and raw files |
| PNG `max_ancillary_bytes`, `max_idat_parts`, `max_mutations` | 32, 4, 4 | rewrites and mutations |
| ICO `max_payloads` | 4 | payloads per file |
| ICO `max_dib_width` x `max_dib_height` | 40 x 24 | DIB payloads |
| ICO `max_png_side` | 16 | PNG payloads |
| ICO `directory_capacity` | 64 | entries, the decoder's limit |
| ICO `allocation_budget` | 812 KiB | live bytes of each fuzzed ICO decode |
| ICO `file_capacity` | 32 KiB | generated, mutated and raw files |

The extreme-header tests use dimensions up to 2^32-1 with low limits, and
reject without allocating.

## Seeds

Each seed is written as the Smith calls it answers. The tests
`every png fuzz seed reaches its case and outcome` and
`every ico fuzz seed reaches its case and outcome` replay each one, and the
empty input, and check the case and outcome.

PNG seeds:

| # | Case | Input | Outcome |
| --- | --- | --- | --- |
| 0 | generated | RGBA8 4x2, Paeth, `fuzz_limits` | image |
| 1 | generated | RGB16 3x2, Average, limit at its pixel count | image |
| 2 | generated | palette 4x2, 3 entries, 2 tRNS, limit at its side | image |
| 3 | generated | RGBA8 2x4, Up, limit at its height | image |
| 4 | generated | RGBA8 4x2, limit one pixel short | `PngTooLarge` |
| 5 | equivalent | ancillary chunk before the data; three IDATs of 5 bytes, 0 bytes and the rest | image |
| 6 | mutated | IHDR width 2^32-1 | `PngTooLarge` |
| 7 | mutated | IHDR height 0 | `InvalidPngData` |
| 8 | mutated | truncated to 32 bytes | `NotPng` |
| 9 | mutated | IHDR CRC broken | `InvalidPngData` |
| 10 | mutated | first IDAT dropped | `InvalidPngData` |
| 11 | raw_chunks | IHDR then IEND | `InvalidPngData` |
| 12 | generated | RGBA8 4x2, then its second allocation fails | image, then `OutOfMemory` |

ICO seeds:

| # | Case | Input | Outcome |
| --- | --- | --- | --- |
| 0 | generated | one 2x2 DIB with alpha, cell 16 | image |
| 1 | generated | 8x8 DIB with mask, 16x16 PNG, 33x3 DIB with mask, cell 10 | the PNG |
| 2 | generated | 24-bit DIB and BI_BITFIELDS DIB, the second with a width mismatch | `UnsupportedIco` |
| 3 | generated | PNG with a broken IHDR CRC | `InvalidPngData` |
| 4 | generated | PNG entry declaring 256, then a reserved byte | `InvalidIcoData` |
| 5 | generated | one 4x4 PNG under two entries of side 4, the first declaring 256, cell 4 | `InvalidIcoData` (the first wins the tie) |
| 6 | generated | DIB with a truncated mask | `InvalidIcoData` |
| 7 | generated | count 65 | `UnsupportedIco` |
| 8 | generated | wrong magic | `NotIco` |
| 9 | mutated | entry offset 2^32-1 | `InvalidIcoData` |
| 10 | raw | `testdata/telar.ico`, cell 32 | image |
| 11 | generated | 4x4 PNG, then its third allocation fails | image, then `OutOfMemory` |

PNG seed 3 and ICO seed 5 come from the sensitivity check below.

## Sensitivity

On a scratch copy of the repository at commit 96a34ba4, three deliberately
wrong changes were made to the library. The checks ran before the
allocation budget existed and before those two seeds were added:

| Change | Found |
| --- | --- |
| `height >= limits.max_side` in `png.decode` | fuzzing, after 66 runs: `expected error.InvalidPngData, found error.PngTooLarge` |
| `side <= previous` in `IcoFrame.preferredTo` (the last entry wins ties) | fuzzing, after 1726 runs: `ICO property failed: UnexpectedImage` |
| no `errdefer image.deinit(gpa)` after a PNG entry decodes | replay: `expected 44764, found 44700` (bytes allocated and freed) |

For the first two, the saved input failed on the changed library once
embedded in the corpus, and passed on the restored one. With seeds PNG 3 and
ICO 5 added, a plain replay catches both changes. None of the changes is
committed.

## What this does not cover

- Wuffs C gives the fuzzer no coverage feedback. The Ghostty Wuffs wrapper is
  instrumented, but no input can pick which of its failure branches runs.
- Grayscale, sub-byte depths and interlaced PNGs are not generated as valid
  fuzz inputs; they reach the fuzzed decoder through IHDR rewrites and raw
  bytes. The budget tests decode valid variants with zero samples.
- ICO PNG payloads are RGBA8 only. The fuzzer generates no 256-pixel image;
  the budget tests and directed rejection tests decode the 256-pixel sizes.
- The reference pixels only cover what `encodeForTest` can encode.
- The allocation budgets rest on sampled images, not on a bound derived from
  Wuffs's code.
