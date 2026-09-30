//! Native fuzzing of `imaging.png.decode`.
//!
//! Each input builds a small PNG from fuzzed samples with the library's
//! `encodeForTest`, then decodes it unchanged, rewritten into an equivalent
//! file, mutated, or followed by raw fuzzed chunks. A generated or equivalent
//! file must decode to exactly the pixels a reference computed here from its
//! samples. Any other file must keep the decoder's contract: what `decode`
//! checks before Wuffs reads the bytes answers with its own error and
//! allocates nothing, anything else is an image of the IHDR's size or
//! `InvalidPngData`, and every allocation is released. An input may also fail
//! one of the allocations its clean decode made, which must surface as
//! `OutOfMemory` with nothing held.
//!
//! Two bounds apply. The admission limits, `fuzz_limits`, are what `decode`
//! checks in the header before Wuffs allocates. The allocation budget,
//! `allocation_budget`, is a hard limit on the bytes one decode holds live:
//! `BoundedTestAllocator` refuses any request past it without reserving it,
//! and every decode must end with no refusal.
//!
//! This root imports the configured `imaging` library and runs only through
//! `zig build test-fuzz-imaging` and `test-fuzz-imaging-png`, built like the
//! handshake fuzz target of commit d519fb1d, whose message records why the
//! suites and the coverage build never compile a `std.testing.fuzz` call.

const std = @import("std");
const imaging = @import("imaging");
const seed = @import("png_fuzz_seed.zig");
const png_file = @import("png_fuzz_file.zig");
const BoundedTestAllocator = @import("BoundedTestAllocator.zig");

const png = imaging.png;
const Smith = std.testing.Smith;
const Weight = Smith.Weight;
const FailingAllocator = std.testing.FailingAllocator;

/// `decode`'s limits and `encodeForTest`'s spec, which the library takes but
/// does not export by name.
const PngLimits = @typeInfo(@TypeOf(png.decode)).@"fn".params[2].type.?;
const PngTestSpec = @typeInfo(@TypeOf(png.encodeForTest)).@"fn".params[1].type.?;
const ColorType = @FieldType(@FieldType(PngTestSpec, "header"), "color");

const signature = png_file.signature;
const chunk_head_bytes = png_file.chunk_head_bytes;
const chunk_crc_bytes = png_file.chunk_crc_bytes;
const ihdr_data_bytes = png_file.ihdr_data_bytes;

/// The signature and the whole IHDR chunk: what `decode` reads before Wuffs.
const header_bytes = signature.len + chunk_head_bytes + ihdr_data_bytes + chunk_crc_bytes;

/// `encodeForTest` filters a scanline into 64 bytes, so no generated row is
/// longer.
const max_row_bytes = 64;
const max_rows = 16;
const max_palette_entries = 256;
const palette_entry_bytes = 3;
const bits_per_byte = 8;
const rgba_bytes = 4;
const max_pixels = max_row_bytes * max_rows;

/// The admission limits every fuzzed decode runs within: `decode` rejects a
/// larger header before Wuffs allocates.
const fuzz_limits: PngLimits = .{
    .max_side = max_row_bytes,
    .max_pixels = max_pixels,
};

/// The most bytes one decode under `fuzz_limits` may hold live. Its value is
/// the largest peak measured over the sampled images of test "the allocation
/// budget sits one rounding above the sampled peak" (56 984 bytes, a 16 x 64
/// RGBA16 image, with Zig 0.16.0 and the pinned Wuffs), rounded up to
/// `budget_rounding`. The samples do not prove every admitted file stays
/// under it; the hard limit does, by failing any fuzzed decode that reaches
/// it. It counts the three allocations the Ghostty wrapper makes: decoder
/// state, pixels and work buffer.
const allocation_budget = 56 * 1024;

/// The measured peak must sit within this below the budget, so a change in
/// Wuffs's allocations shows up as a failing test, not a silent margin.
const budget_rounding = 4 * 1024;

/// The image the measurement peaks at, RGBA with 16-bit samples.
const largest_image_width = 16;
const largest_image_height = 64;

/// Room for the largest generated file with what a rewrite or mutation adds.
const file_capacity = 8 * 1024;

/// Chunks a file is walked for; a generated one has at most six.
const max_chunks = 16;
const max_ancillary_bytes = 32;
const max_idat_parts = 4;
const max_mutations = 4;

/// An unknown chunk every decoder must skip: ancillary, private, reserved
/// bit clear and safe to copy.
const ancillary_kind = "fuZz";

/// An IHDR field, valued at its offset inside the chunk's data.
const IhdrField = enum(u8) {
    width = 0,
    height = 4,
    depth = 8,
    color = 9,
    compression = 10,
    filter = 11,
    interlace = 12,
};

const FilterType = enum(u8) {
    none,
    sub,
    up,
    average,
    paeth,
};

const SampleDepth = enum(u8) {
    eight = 8,
    sixteen = 16,
};

/// Where the limits sit against the generated image's size.
const LimitsChoice = enum {
    fuzz_limits,
    exact_side,
    short_side,
    exact_pixels,
    short_pixels,
};

/// What an input does to the generated file before decoding it.
const PngCase = enum {
    generated,
    equivalent,
    mutated,
    raw_chunks,
};

/// Where an equivalent rewrite puts its unknown ancillary chunk.
const AncillaryPlace = enum {
    none,
    after_header,
    before_data,
    after_data,
};

const PngMutation = enum {
    flip_byte,
    set_byte,
    truncate,
    rewrite_header,
    chunk_length,
    chunk_crc,
    drop_chunk,
    duplicate_chunk,
};

/// Widths and heights a rewritten IHDR takes: around the fuzz limits, and
/// the extremes whose area overflows 32 bits.
const dimension_weights = [_]Weight{
    .rangeAtMost(
        u32,
        0,
        max_row_bytes + 1,
        1 << 26,
    ),
    .value(
        u32,
        1 << 16,
        1 << 30,
    ),
    .value(
        u32,
        1 << 31,
        1 << 30,
    ),
    .value(
        u32,
        std.math.maxInt(u32),
        1 << 30,
    ),
    .rangeAtMost(
        u32,
        0,
        std.math.maxInt(u32),
        1,
    ),
};

/// Chunk lengths a mutation writes: within the file, and the extremes.
const length_weights = [_]Weight{
    .rangeAtMost(
        u32,
        0,
        file_capacity,
        1 << 20,
    ),
    .value(
        u32,
        std.math.maxInt(u31),
        1 << 30,
    ),
    .value(
        u32,
        std.math.maxInt(u32),
        1 << 30,
    ),
    .rangeAtMost(
        u32,
        0,
        std.math.maxInt(u32),
        1,
    ),
};

/// A PNG this file generated and the samples it encodes.
const GeneratedPng = struct {
    width: u32,
    height: u32,
    color: ColorType,
    depth: SampleDepth,
    filter: FilterType,
    samples: [max_row_bytes * max_rows]u8,
    palette: [max_palette_entries * palette_entry_bytes]u8,
    palette_entries: u16,
    transparency: [max_palette_entries]u8,
    transparency_len: u16,
};

/// Where one chunk sits in a file.
const ChunkSpan = struct {
    start: usize,
    data_len: usize,

    fn end(self: ChunkSpan) usize {
        return self.start + chunk_head_bytes + self.data_len + chunk_crc_bytes;
    }

    fn kind(self: ChunkSpan, bytes: []const u8) []const u8 {
        return bytes[self.start + 4 ..][0..4];
    }
};

/// A file being built or mutated in place.
const PngFile = struct {
    bytes: [file_capacity]u8,
    len: usize,

    fn written(self: *const PngFile) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// What decoding one input produced: its case, the error or null for an
/// image, and whether an allocation failure was injected after it.
const PngTrial = struct {
    case: PngCase,
    outcome: ?png.Error,
    failed_allocation: bool,
};

/// A clean decode's outcome and how many allocations it made.
const PngDecoding = struct {
    outcome: ?png.Error,
    allocations: usize,
};

/// A seed's Smith input and what replaying it must produce.
const PngSeed = struct {
    input: []const u8,
    trial: PngTrial,
};

const rgba_samples = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 } ++
    [_]u8{ 1, 2, 3, 4, 250, 240, 230, 220, 100, 100, 100, 100, 0, 0, 0, 255 };

const rgb16_samples = [_]u8{ 255, 1, 0, 255, 128, 13, 0, 255, 255, 0, 32, 129, 7, 7, 8, 8, 9, 9 } ++
    [_]u8{ 10, 200, 20, 100, 30, 50, 1, 128, 2, 64, 3, 32, 0, 0, 255, 255, 1, 1 };

/// A 4x2 RGBA image with the Paeth filter within the fuzz limits.
const rgba_input = seed.input(&.{
    seed.tag(ColorType.rgba),
    seed.tag(SampleDepth.eight),
    seed.int(4),
    seed.int(2),
    seed.tag(FilterType.paeth),
    seed.bytes(&rgba_samples),
    seed.tag(LimitsChoice.fuzz_limits),
});

const png_seeds = [_]PngSeed{
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{seed.tag(PngCase.generated)}),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.input(&.{
            seed.tag(ColorType.rgb),
            seed.tag(SampleDepth.sixteen),
            seed.int(3),
            seed.int(2),
            seed.tag(FilterType.average),
            seed.bytes(&rgb16_samples),
            seed.tag(LimitsChoice.exact_pixels),
            seed.tag(PngCase.generated),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.input(&.{
            seed.tag(ColorType.palette),
            seed.int(4),
            seed.int(2),
            seed.tag(FilterType.sub),
            seed.bytes(&.{ 0, 1, 2, 1, 2, 2, 0, 1 }),
            seed.int(3),
            seed.bytes(&.{ 10, 20, 30, 40, 50, 60, 70, 80, 90 }),
            seed.int(2),
            seed.bytes(&.{ 255, 128 }),
            seed.tag(LimitsChoice.exact_side),
            seed.tag(PngCase.generated),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.input(&.{
            seed.tag(ColorType.rgba),
            seed.tag(SampleDepth.eight),
            seed.int(2),
            seed.int(4),
            seed.tag(FilterType.up),
            seed.bytes(&rgba_samples),
            seed.tag(LimitsChoice.exact_side),
            seed.tag(PngCase.generated),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.input(&.{
            seed.tag(ColorType.rgba),
            seed.tag(SampleDepth.eight),
            seed.int(4),
            seed.int(2),
            seed.tag(FilterType.paeth),
            seed.bytes(&rgba_samples),
            seed.tag(LimitsChoice.short_pixels),
            seed.tag(PngCase.generated),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.PngTooLarge,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.equivalent),
                seed.tag(AncillaryPlace.before_data),
                seed.int(5),
                seed.bytes("telar"),
                seed.int(3),
                seed.int(5),
                seed.int(0),
            }),
        }),
        .trial = .{
            .case = .equivalent,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.mutated),
                seed.int(1),
                seed.tag(PngMutation.rewrite_header),
                seed.tag(IhdrField.width),
                seed.int(std.math.maxInt(u32)),
            }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.PngTooLarge,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.mutated),
                seed.int(1),
                seed.tag(PngMutation.rewrite_header),
                seed.tag(IhdrField.height),
                seed.int(0),
            }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.InvalidPngData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.mutated),
                seed.int(1),
                seed.tag(PngMutation.truncate),
                seed.int(header_bytes - 1),
            }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.NotPng,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.mutated),
                seed.int(1),
                seed.tag(PngMutation.chunk_crc),
                seed.int(0),
                seed.int(1),
            }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.InvalidPngData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.mutated),
                seed.int(1),
                seed.tag(PngMutation.drop_chunk),
                seed.int(1),
            }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.InvalidPngData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.raw_chunks),
                seed.sliceLength(12),
                seed.bytes(&.{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 }),
            }),
        }),
        .trial = .{
            .case = .raw_chunks,
            .outcome = error.InvalidPngData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            rgba_input,
            seed.input(&.{
                seed.tag(PngCase.generated),
                seed.int(1),
                seed.int(1),
            }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = true,
        },
    },
};

/// The seeds' inputs. A crash the fuzzer saves has the same form, so it can
/// join this corpus as it is.
const png_corpus = corpus: {
    var entries: [png_seeds.len][]const u8 = undefined;
    for (png_seeds, &entries) |png_seed, *entry| {
        entry.* = png_seed.input;
    }

    break :corpus entries;
};

fn channels(color: ColorType) u8 {
    return switch (color) {
        .rgb => 3,
        .palette => 1,
        .rgba => 4,
    };
}

fn bytesPerPixel(color: ColorType, depth: SampleDepth) u8 {
    return channels(color) * (@intFromEnum(depth) / bits_per_byte);
}

/// A PNG of at most `max_row_bytes` by `max_rows` in a color type and depth
/// `encodeForTest` writes, with palette indices inside the palette.
fn generatePng(smith: *Smith) GeneratedPng {
    var generated: GeneratedPng = undefined;
    generated.color = smith.value(ColorType);
    generated.depth = if (generated.color == .palette) .eight else smith.value(SampleDepth);

    const pixel_bytes = bytesPerPixel(generated.color, generated.depth);
    generated.width = smith.valueRangeAtMost(
        u32,
        1,
        max_row_bytes / pixel_bytes,
    );
    generated.height = smith.valueRangeAtMost(
        u32,
        1,
        max_rows,
    );
    generated.filter = smith.value(FilterType);

    const samples = generated.samples[0 .. generated.width * pixel_bytes * generated.height];
    smith.bytes(samples);

    generated.palette_entries = 0;
    generated.transparency_len = 0;
    if (generated.color != .palette) {
        return generated;
    }

    generated.palette_entries = smith.valueRangeAtMost(
        u16,
        1,
        max_palette_entries,
    );
    for (samples) |*sample| {
        sample.* = @intCast(sample.* % generated.palette_entries);
    }

    smith.bytes(generated.palette[0 .. @as(usize, generated.palette_entries) * palette_entry_bytes]);
    generated.transparency_len = smith.valueRangeAtMost(
        u16,
        0,
        generated.palette_entries,
    );
    smith.bytes(generated.transparency[0..generated.transparency_len]);
    return generated;
}

fn sampleLen(generated: *const GeneratedPng) usize {
    return @as(usize, generated.width) * bytesPerPixel(generated.color, generated.depth) * generated.height;
}

/// The straight RGBA8 the decoder owes a generated PNG, computed from its
/// samples without the decoder: 16-bit samples keep their high byte, RGB is
/// opaque and a palette index missing from tRNS is opaque.
fn expectedPixels(generated: *const GeneratedPng, pixels: []u8) void {
    const pixel_bytes = bytesPerPixel(generated.color, generated.depth);
    const sample_bytes = @intFromEnum(generated.depth) / bits_per_byte;
    for (0..@as(usize, generated.width) * generated.height) |index| {
        const pixel = generated.samples[index * pixel_bytes ..][0..pixel_bytes];
        const rgba = pixels[index * rgba_bytes ..][0..rgba_bytes];
        const alpha = &rgba[rgba_bytes - 1];
        if (generated.color == .palette) {
            const entry = pixel[0];
            rgba[0..palette_entry_bytes].* = generated.palette[@as(usize, entry) * palette_entry_bytes ..][0..palette_entry_bytes].*;
            alpha.* = if (entry < generated.transparency_len) generated.transparency[entry] else std.math.maxInt(u8);
            continue;
        }

        for (0..channels(generated.color)) |channel| {
            rgba[channel] = pixel[channel * sample_bytes];
        }

        if (generated.color == .rgb) {
            alpha.* = std.math.maxInt(u8);
        }
    }
}

fn encode(generated: *const GeneratedPng, file: *PngFile) !void {
    const gpa = std.testing.allocator;
    const bytes = try png.encodeForTest(
        gpa,
        .{
            .header = .{
                .width = generated.width,
                .height = generated.height,
                .color = generated.color,
                .depth = @intFromEnum(generated.depth),
            },
            .filter = @intFromEnum(generated.filter),
            .palette = generated.palette[0 .. @as(usize, generated.palette_entries) * palette_entry_bytes],
            .transparency = generated.transparency[0..generated.transparency_len],
        },
        generated.samples[0..sampleLen(generated)],
    );
    defer gpa.free(bytes);

    @memcpy(file.bytes[0..bytes.len], bytes);
    file.len = bytes.len;
}

fn chooseLimits(smith: *Smith, width: u32, height: u32) PngLimits {
    const side = @max(width, height);
    const area = width * height;
    return switch (smith.value(LimitsChoice)) {
        .fuzz_limits => fuzz_limits,
        .exact_side => .{
            .max_side = side,
            .max_pixels = fuzz_limits.max_pixels,
        },
        .short_side => .{
            .max_side = side - 1,
            .max_pixels = fuzz_limits.max_pixels,
        },
        .exact_pixels => .{
            .max_side = fuzz_limits.max_side,
            .max_pixels = area,
        },
        .short_pixels => .{
            .max_side = fuzz_limits.max_side,
            .max_pixels = area - 1,
        },
    };
}

fn equalBytes(a: []const u8, b: []const u8) bool {
    return std.mem.eql(
        u8,
        a,
        b,
    );
}

/// A PNG integer: four bytes, most significant first.
fn readBig(bytes: *const [4]u8) u32 {
    return std.mem.readInt(
        u32,
        bytes,
        .big,
    );
}

fn writeBig(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(
        u32,
        bytes,
        value,
        .big,
    );
}

/// The chunks laid end to end after the signature, up to the first that
/// does not fit in `bytes`.
fn chunkSpans(bytes: []const u8, spans: *[max_chunks]ChunkSpan) []const ChunkSpan {
    var count: usize = 0;
    var start: usize = signature.len;
    while (count < max_chunks and start + chunk_head_bytes + chunk_crc_bytes <= bytes.len) {
        const span: ChunkSpan = .{
            .start = start,
            .data_len = readBig(bytes[start..][0..4]),
        };
        if (span.data_len > bytes.len or span.end() > bytes.len) {
            break;
        }

        spans[count] = span;
        count += 1;
        start = span.end();
    }

    return spans[0..count];
}

/// Rewrites a generated file into one every conforming decoder reads as the
/// same image: its zlib stream split into other IDAT chunks, and maybe an
/// unknown ancillary chunk after IHDR, before the data or after it.
fn writeEquivalent(smith: *Smith, original: []const u8, file: *PngFile) !void {
    var spans_buffer: [max_chunks]ChunkSpan = undefined;
    const spans = chunkSpans(original, &spans_buffer);

    var stream_buffer: [file_capacity]u8 = undefined;
    var stream_len: usize = 0;
    for (spans) |span| {
        if (equalBytes(span.kind(original), "IDAT")) {
            @memcpy(stream_buffer[stream_len..][0..span.data_len], original[span.start + chunk_head_bytes ..][0..span.data_len]);
            stream_len += span.data_len;
        }
    }

    const place = smith.value(AncillaryPlace);
    var ancillary_buffer: [max_ancillary_bytes]u8 = undefined;
    const ancillary_len = smith.valueRangeAtMost(
        u8,
        0,
        max_ancillary_bytes,
    );
    const ancillary = ancillary_buffer[0..ancillary_len];
    smith.bytes(ancillary);

    var out: std.Io.Writer = .fixed(&file.bytes);
    try out.writeAll(signature);
    for (spans) |span| {
        const kind = span.kind(original);
        if (equalBytes(kind, "IDAT") or equalBytes(kind, "IEND")) {
            continue;
        }

        try out.writeAll(original[span.start..span.end()]);
        if (place == .after_header and equalBytes(kind, "IHDR")) {
            try png_file.writeChunk(
                &out,
                ancillary_kind,
                ancillary,
            );
        }
    }

    if (place == .before_data) {
        try png_file.writeChunk(
            &out,
            ancillary_kind,
            ancillary,
        );
    }

    const parts = smith.valueRangeAtMost(
        u8,
        1,
        max_idat_parts,
    );
    var stream = stream_buffer[0..stream_len];
    for (1..parts) |_| {
        const part_len = smith.valueRangeAtMost(
            u32,
            0,
            @intCast(stream.len),
        );
        try png_file.writeChunk(
            &out,
            "IDAT",
            stream[0..part_len],
        );
        stream = stream[part_len..];
    }

    try png_file.writeChunk(
        &out,
        "IDAT",
        stream,
    );
    if (place == .after_data) {
        try png_file.writeChunk(
            &out,
            ancillary_kind,
            ancillary,
        );
    }

    try png_file.writeChunk(
        &out,
        "IEND",
        &.{},
    );
    file.len = out.end;
}

/// Applies up to `max_mutations` byte, header and chunk mutations. A
/// rewritten IHDR field gets a matching CRC so it reaches the limit checks;
/// other chunk edits keep their CRC.
fn mutate(smith: *Smith, file: *PngFile) void {
    const count = smith.valueRangeAtMost(
        u8,
        1,
        max_mutations,
    );
    for (0..count) |_| {
        if (file.len == 0) {
            return;
        }

        switch (smith.value(PngMutation)) {
            .flip_byte => file.bytes[smith.index(file.len)] ^= nonZeroByte(smith),
            .set_byte => file.bytes[smith.index(file.len)] = smith.value(u8),
            .truncate => file.len = smith.index(file.len),
            .rewrite_header => rewriteHeader(smith, file),
            .chunk_length, .chunk_crc, .drop_chunk, .duplicate_chunk => |mutation| mutateChunk(
                smith,
                file,
                mutation,
            ),
        }
    }
}

/// A byte that changes whatever it is XORed into.
fn nonZeroByte(smith: *Smith) u8 {
    return smith.valueRangeAtMost(
        u8,
        1,
        std.math.maxInt(u8),
    );
}

fn rewriteHeader(smith: *Smith, file: *PngFile) void {
    const field = smith.value(IhdrField);
    if (file.len < header_bytes) {
        return;
    }

    const data = file.bytes[signature.len + chunk_head_bytes ..][0..ihdr_data_bytes];
    switch (field) {
        .width, .height => writeBig(data[@intFromEnum(field)..][0..4], smith.valueWeighted(u32, &dimension_weights)),
        else => data[@intFromEnum(field)] = smith.value(u8),
    }

    const kind_and_data = file.bytes[signature.len + 4 ..][0 .. 4 + ihdr_data_bytes];
    writeBig(file.bytes[header_bytes - chunk_crc_bytes ..][0..4], std.hash.Crc32.hash(kind_and_data));
}

fn mutateChunk(smith: *Smith, file: *PngFile, mutation: PngMutation) void {
    var spans_buffer: [max_chunks]ChunkSpan = undefined;
    const spans = chunkSpans(file.written(), &spans_buffer);
    if (spans.len == 0) {
        return;
    }

    const span = spans[smith.index(spans.len)];
    const chunk_len = span.end() - span.start;
    switch (mutation) {
        .chunk_length => writeBig(file.bytes[span.start..][0..4], smith.valueWeighted(u32, &length_weights)),
        .chunk_crc => file.bytes[span.end() - 1] ^= nonZeroByte(smith),
        .drop_chunk => {
            std.mem.copyForwards(
                u8,
                file.bytes[span.start..],
                file.bytes[span.end()..file.len],
            );
            file.len -= chunk_len;
        },
        .duplicate_chunk => {
            if (file.len + chunk_len > file_capacity) {
                return;
            }

            std.mem.copyBackwards(
                u8,
                file.bytes[span.end() + chunk_len ..],
                file.bytes[span.end()..file.len],
            );
            @memcpy(file.bytes[span.end()..][0..chunk_len], file.bytes[span.start..span.end()]);
            file.len += chunk_len;
        },
        else => unreachable,
    }
}

/// A valid signature and IHDR followed by whatever chunk bytes the fuzzer
/// writes.
fn writeRawChunks(smith: *Smith, original: []const u8, file: *PngFile) void {
    @memcpy(file.bytes[0..header_bytes], original[0..header_bytes]);
    file.len = header_bytes + smith.slice(file.bytes[header_bytes..]);
}

/// The error `decode` owes `bytes` before Wuffs reads them, in the order it
/// checks: signature and length, IHDR length and type, IHDR CRC, empty
/// dimensions, then the limits.
fn expectedHeaderRejection(bytes: []const u8, limits: PngLimits) ?png.Error {
    if (bytes.len < header_bytes or !equalBytes(bytes[0..signature.len], signature)) {
        return error.NotPng;
    }

    const chunk = bytes[signature.len..header_bytes];
    if (readBig(chunk[0..4]) != ihdr_data_bytes or !equalBytes(chunk[4..8], "IHDR")) {
        return error.InvalidPngData;
    }

    const data_end = chunk_head_bytes + ihdr_data_bytes;
    if (readBig(chunk[data_end..][0..4]) != std.hash.Crc32.hash(chunk[4..data_end])) {
        return error.InvalidPngData;
    }

    const width, const height = headerDimensions(bytes);
    if (width == 0 or height == 0) {
        return error.InvalidPngData;
    }

    if (width > limits.max_side or height > limits.max_side or @as(u64, width) * height > limits.max_pixels) {
        return error.PngTooLarge;
    }

    return null;
}

fn headerDimensions(bytes: []const u8) struct { u32, u32 } {
    const data = bytes[signature.len + chunk_head_bytes ..][0..ihdr_data_bytes];
    return .{
        readBig(data[@intFromEnum(IhdrField.width)..][0..4]),
        readBig(data[@intFromEnum(IhdrField.height)..][0..4]),
    };
}

/// Decodes `bytes` once without failing allocations, under the hard
/// `allocation_budget`. A header rejection must be exactly the one owed and
/// allocate nothing; past the header only `InvalidPngData` may reject, never
/// a file with `reference` pixels; an image has the IHDR's dimensions, four
/// bytes per pixel and, for a reference, exactly its pixels. No request may
/// be refused by the budget, and every allocation is released.
fn expectDecoding(bytes: []const u8, limits: PngLimits, reference: ?[]const u8) !PngDecoding {
    var bounded: BoundedTestAllocator = .init(std.testing.allocator, allocation_budget);
    var failing: FailingAllocator = .init(bounded.allocator(), .{});
    const gpa = failing.allocator();
    const rejection = expectedHeaderRejection(bytes, limits);

    const decoded = png.decode(
        gpa,
        bytes,
        limits,
    );
    const outcome: ?png.Error = if (decoded) |accepted_image| accepted: {
        var image = accepted_image;
        defer image.deinit(gpa);

        try std.testing.expectEqual(null, rejection);

        const width, const height = headerDimensions(bytes);
        try std.testing.expectEqual(width, image.width);
        try std.testing.expectEqual(height, image.height);
        try std.testing.expectEqual(@as(usize, width) * height * rgba_bytes, image.pixels.len);
        if (reference) |pixels| {
            try std.testing.expectEqualSlices(
                u8,
                pixels,
                image.pixels,
            );
        }

        break :accepted null;
    } else |err| rejected: {
        if (rejection) |owed| {
            try std.testing.expectEqual(owed, err);
            try std.testing.expectEqual(0, failing.allocations);
        } else {
            try std.testing.expectEqual(null, reference);
            try std.testing.expectEqual(error.InvalidPngData, err);
        }

        break :rejected err;
    };

    try seed.expectReleased(&failing);
    try seed.expectWithinBudget(&bounded);
    return .{
        .outcome = outcome,
        .allocations = failing.allocations,
    };
}

/// Maybe fails one of the `allocations` the clean decode made. Decoding is
/// deterministic, so that allocation is reached and its failure must be
/// `OutOfMemory` with everything released and nothing refused.
fn expectAllocationFailure(smith: *Smith, bytes: []const u8, limits: PngLimits, allocations: usize) !bool {
    if (allocations == 0 or !smith.valueWeighted(bool, &seed.failure_weights)) {
        return false;
    }

    var bounded: BoundedTestAllocator = .init(std.testing.allocator, allocation_budget);
    var failing: FailingAllocator = .init(
        bounded.allocator(),
        .{
            .fail_index = smith.index(allocations),
        },
    );
    const gpa = failing.allocator();
    const decoded = png.decode(
        gpa,
        bytes,
        limits,
    );
    if (decoded) |accepted_image| {
        var image = accepted_image;
        image.deinit(gpa);
        return error.AllocationFailureIgnored;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    try seed.expectReleased(&failing);
    try seed.expectWithinBudget(&bounded);
    return true;
}

/// A broken property panics rather than returning its error, as the
/// handshake fuzz target does. Wuffs warns on every rejection, which only
/// slows the fuzzer, so warnings are muted here.
fn decodeFuzzedPng(_: void, smith: *Smith) anyerror!void {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;

    _ = expectPngDecoding(smith) catch |err| std.debug.panic("PNG property failed: {t}", .{err});
}

fn expectPngDecoding(smith: *Smith) !PngTrial {
    const generated = generatePng(smith);
    const limits = chooseLimits(
        smith,
        generated.width,
        generated.height,
    );
    const case = smith.value(PngCase);

    var original: PngFile = undefined;
    try encode(&generated, &original);

    var reference_buffer: [max_pixels * rgba_bytes]u8 = undefined;
    const reference = reference_buffer[0 .. @as(usize, generated.width) * generated.height * rgba_bytes];
    expectedPixels(&generated, reference);

    var rewritten: PngFile = undefined;
    const bytes: []const u8, const owed: ?[]const u8 = switch (case) {
        .generated => .{ original.written(), reference },
        .equivalent => equivalent: {
            try writeEquivalent(
                smith,
                original.written(),
                &rewritten,
            );
            break :equivalent .{ rewritten.written(), reference };
        },
        .mutated => mutated: {
            rewritten = original;
            mutate(smith, &rewritten);
            break :mutated .{ rewritten.written(), null };
        },
        .raw_chunks => raw: {
            writeRawChunks(
                smith,
                original.written(),
                &rewritten,
            );
            break :raw .{ rewritten.written(), null };
        },
    };

    const decoding = try expectDecoding(
        bytes,
        limits,
        owed,
    );
    return .{
        .case = case,
        .outcome = decoding.outcome,
        .failed_allocation = try expectAllocationFailure(
            smith,
            bytes,
            limits,
            decoding.allocations,
        ),
    };
}

fn replay(input: []const u8) !PngTrial {
    var smith: Smith = .{
        .in = input,
    };
    return expectPngDecoding(&smith);
}

/// Encodes `header` with a matching CRC and nothing after it.
fn headerOnly(width: u32, height: u32) [header_bytes]u8 {
    var bytes: [header_bytes]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    out.writeAll(signature) catch unreachable;

    var data: [ihdr_data_bytes]u8 = @splat(0);
    writeBig(data[@intFromEnum(IhdrField.width)..][0..4], width);
    writeBig(data[@intFromEnum(IhdrField.height)..][0..4], height);
    data[@intFromEnum(IhdrField.depth)] = @intFromEnum(SampleDepth.eight);
    data[@intFromEnum(IhdrField.color)] = @intFromEnum(ColorType.rgba);
    png_file.writeChunk(
        &out,
        "IHDR",
        &data,
    ) catch unreachable;
    return bytes;
}

/// Decodes `bytes`, which must succeed, with no limit on the allocator, and
/// returns the most bytes the decode held live at once.
fn decodePeak(bytes: []const u8, limits: PngLimits) !usize {
    var bounded: BoundedTestAllocator = .init(std.testing.allocator, std.math.maxInt(usize));
    const gpa = bounded.allocator();
    var image = try png.decode(
        gpa,
        bytes,
        limits,
    );
    image.deinit(gpa);

    try std.testing.expectEqual(0, bounded.live_bytes);
    return bounded.peak_bytes;
}

/// The largest peak over the sampled images: a zero-sample PNG in every
/// color type, bit depth and interlacing, at every width up to
/// `limits.max_side`, each with the tallest height `limits` then admit.
fn measureSampledPeak(limits: PngLimits) !usize {
    var largest: usize = 0;
    for (png_file.color_depths) |color_depth| {
        for ([_]bool{ false, true }) |interlaced| {
            for (1..limits.max_side + 1) |width| {
                const height: u32 = @intCast(@min(limits.max_side, limits.max_pixels / width));
                const bytes = try png_file.zeroPng(
                    std.testing.allocator,
                    .{
                        .width = @intCast(width),
                        .height = height,
                        .color_depth = color_depth,
                        .interlaced = interlaced,
                    },
                );
                defer std.testing.allocator.free(bytes);

                largest = @max(largest, try decodePeak(bytes, limits));
            }
        }
    }

    return largest;
}

test "every png fuzz seed reaches its case and outcome" {
    for (png_seeds) |png_seed| {
        try std.testing.expectEqual(png_seed.trial, try replay(png_seed.input));
    }

    try std.testing.expectEqual(
        PngTrial{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
        try replay(""),
    );
}

test "the allocation budget sits one rounding above the sampled peak, and a request past a limit is refused unreserved" {
    const peak = try measureSampledPeak(fuzz_limits);
    try std.testing.expect(peak <= allocation_budget);
    try std.testing.expect(allocation_budget - peak < budget_rounding);

    // The image the measurement peaks at, decoded under one byte less.
    const largest = try png_file.zeroPng(
        std.testing.allocator,
        .{
            .width = largest_image_width,
            .height = largest_image_height,
            .color_depth = .{
                .color = .rgba,
                .depth = @intFromEnum(SampleDepth.sixteen),
            },
            .interlaced = false,
        },
    );
    defer std.testing.allocator.free(largest);
    try std.testing.expectEqual(peak, try decodePeak(largest, fuzz_limits));

    var backing: BoundedTestAllocator = .init(std.testing.allocator, std.math.maxInt(usize));
    var bounded: BoundedTestAllocator = .init(backing.allocator(), peak - 1);
    const decoded = png.decode(
        bounded.allocator(),
        largest,
        fuzz_limits,
    );
    try std.testing.expectError(error.OutOfMemory, decoded);
    try std.testing.expectEqual(1, bounded.refusals);
    try std.testing.expect(backing.peak_bytes < peak);
    try std.testing.expectEqual(0, backing.live_bytes);
}

test "headers with extreme dimensions are rejected before any allocation" {
    const Rejection = struct {
        width: u32,
        height: u32,
        limits: PngLimits,
        outcome: png.Error,
    };

    const max = std.math.maxInt(u32);
    const loose: PngLimits = .{
        .max_side = max,
        .max_pixels = max_pixels,
    };
    const rejections = [_]Rejection{
        .{
            .width = 0,
            .height = 1,
            .limits = fuzz_limits,
            .outcome = error.InvalidPngData,
        },
        .{
            .width = 1,
            .height = 0,
            .limits = fuzz_limits,
            .outcome = error.InvalidPngData,
        },
        .{
            .width = max,
            .height = max,
            .limits = .{},
            .outcome = error.PngTooLarge,
        },
        .{
            .width = max,
            .height = 1,
            .limits = loose,
            .outcome = error.PngTooLarge,
        },
        .{
            .width = 1 << 16,
            .height = 1 << 16,
            .limits = loose,
            .outcome = error.PngTooLarge,
        },
        .{
            .width = 1 << 31,
            .height = 2,
            .limits = loose,
            .outcome = error.PngTooLarge,
        },
        .{
            .width = max_row_bytes + 1,
            .height = 1,
            .limits = fuzz_limits,
            .outcome = error.PngTooLarge,
        },
        .{
            .width = max_row_bytes,
            .height = max_rows + 1,
            .limits = fuzz_limits,
            .outcome = error.PngTooLarge,
        },
    };
    for (rejections) |rejection| {
        const bytes = headerOnly(rejection.width, rejection.height);
        var failing: FailingAllocator = .init(
            std.testing.allocator,
            .{
                .fail_index = 0,
            },
        );
        const decoded = png.decode(
            failing.allocator(),
            &bytes,
            rejection.limits,
        );
        try std.testing.expectError(rejection.outcome, decoded);
        try std.testing.expectEqual(0, failing.allocations);
        try std.testing.expectEqual(false, failing.has_induced_failure);
    }

    // At the fuzz limits the header passes and Wuffs finds no data.
    const admitted = headerOnly(max_row_bytes, max_rows);
    try std.testing.expectEqual(null, expectedHeaderRejection(&admitted, fuzz_limits));
    const decoded = png.decode(
        std.testing.allocator,
        &admitted,
        fuzz_limits,
    );
    try std.testing.expectError(error.InvalidPngData, decoded);
}

test "representative PNGs release every allocation failure within the budget" {
    for (png_corpus[0..3]) |entry| {
        var smith: Smith = .{
            .in = entry,
        };
        const generated = generatePng(&smith);
        var file: PngFile = undefined;
        try encode(&generated, &file);

        var reference: [max_pixels * rgba_bytes]u8 = undefined;
        expectedPixels(&generated, &reference);

        var bounded: BoundedTestAllocator = .init(std.testing.allocator, allocation_budget);
        try std.testing.checkAllAllocationFailures(
            bounded.allocator(),
            expectReferenceDecoding,
            .{
                file.written(),
                reference[0 .. @as(usize, generated.width) * generated.height * rgba_bytes],
            },
        );
        try seed.expectWithinBudget(&bounded);
    }
}

fn expectReferenceDecoding(gpa: std.mem.Allocator, bytes: []const u8, reference: []const u8) !void {
    var image = try png.decode(
        gpa,
        bytes,
        fuzz_limits,
    );
    defer image.deinit(gpa);

    try std.testing.expectEqualSlices(
        u8,
        reference,
        image.pixels,
    );
}

test "fuzz png decoding" {
    try std.testing.fuzz(
        {},
        decodeFuzzedPng,
        .{
            .corpus = &png_corpus,
        },
    );
}
