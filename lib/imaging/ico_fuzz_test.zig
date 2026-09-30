//! Native fuzzing of `imaging.ico.decode`.
//!
//! Each input generates a small ICO: up to four 32-bit DIB or PNG payloads
//! from fuzzed pixels and masks, and a directory of up to 64 entries that
//! share them, each maybe carrying one defect whose outcome is known. The
//! file is decoded as generated, after byte and entry mutations, or replaced
//! by raw fuzzed bytes. A generated file must answer exactly what a reference
//! here computes: the directory error, `UnsupportedIco` when every entry is
//! skipped, or the pixels of the entry closest to the cell. Mutated and raw
//! files must keep the contract: header errors come before any allocation,
//! rejections come from the ICO and PNG error sets, an image has the
//! dimensions of a directory entry, and every allocation is released. An
//! input may also fail one of the allocations its clean decode made, which
//! must surface as `OutOfMemory` with nothing held.
//!
//! This root imports the configured `imaging` library and runs only through
//! `zig build test-fuzz-imaging` and `test-fuzz-imaging-ico`, for the reasons
//! `png_fuzz_test.zig` gives.

const std = @import("std");
const imaging = @import("imaging");
const seed = @import("png_fuzz_seed.zig");

const ico = imaging.ico;
const png = imaging.png;
const Smith = std.testing.Smith;
const Weight = Smith.Weight;
const FailingAllocator = std.testing.FailingAllocator;

const magic = "\x00\x00\x01\x00";

/// The magic and the entry count.
const directory_head_bytes = 6;
const entry_bytes = 16;

/// The most entries `decode` inspects, and the side a width or height
/// byte of 0 declares, which is the largest an entry decodes to.
const directory_capacity = 64;
const max_entry_side = 256;

const bitmap_header_bytes = 40;
const png_signature_bytes = 8;

/// A PNG chunk's length and type before its data.
const png_chunk_head_bytes = 8;
const png_ihdr_data_bytes = 13;

/// Where a PNG payload's IHDR chunk starts, and the first byte of its CRC.
const png_ihdr_offset = png_signature_bytes;
const png_ihdr_crc_offset = png_ihdr_offset + png_chunk_head_bytes + png_ihdr_data_bytes;

/// The bit count, compression and palette size that make a DIB unsupported:
/// 24 bits per pixel, BI_BITFIELDS and a 16-color table.
const unsupported_bit_count = 24;
const bitfields_compression = 3;
const unsupported_colors_used = 16;

/// The one bit of a mask byte that hides its leftmost pixel.
const leftmost_mask_bit = 0x80;

const max_payloads = 4;

/// DIB payloads are wide enough for a second mask word per row; PNG
/// payloads are RGBA rows `encodeForTest` filters into 64 bytes.
const max_dib_width = 40;
const max_dib_height = 24;
const max_png_side = 16;
const max_payload_pixels = max_dib_width * max_dib_height;
const max_mask_stride = ((max_dib_width + 31) / 32) * 4;

/// Room for a generated file and for the raw inputs, which include the
/// versioned 32 KiB favicon.
const file_capacity = 32 * 1024;
const max_mutations = 4;

/// Offsets of the fields a directory entry holds.
const EntryField = enum(u8) {
    width = 0,
    height = 1,
    reserved = 3,
    size = 8,
    offset = 12,
};

/// Offsets of the BITMAPINFOHEADER fields a DIB payload writes.
const BitmapField = enum(u8) {
    header_size = 0,
    width = 4,
    height = 8,
    planes = 12,
    bit_count = 14,
    compression = 16,
    colors_used = 32,
};

const PayloadFormat = enum {
    dib,
    png,
};

/// Whether a DIB keeps its alpha channel or leaves it empty for the mask.
const AlphaSource = enum {
    alpha,
    mask,
};

const FilterType = enum(u8) {
    none,
    sub,
    up,
    average,
    paeth,
};

/// A payload's one defect: a DIB that is skipped (`unsupported_*`,
/// `compressed`, `color_table`), one that is invalid, or a PNG whose IHDR CRC
/// is broken.
const PayloadDefect = enum {
    none,
    unsupported_depth,
    compressed,
    color_table,
    wrong_planes,
    wrong_height,
    truncated_mask,
    broken_png_header,
};

const EntryDefect = enum {
    none,
    reserved,
    offset_before_directory,
    offset_past_end,
    size_past_end,
    width_mismatch,
};

const HeaderDefect = enum {
    none,
    too_short,
    bad_magic,
    no_entries,
    too_many_entries,
    short_directory,
};

const IcoCase = enum {
    generated,
    mutated,
    raw,
};

const IcoMutation = enum {
    flip_byte,
    set_byte,
    truncate,
    rewrite_entry,
};

const dib_defect_weights = [_]Weight{
    .value(PayloadDefect, .none, 18),
    .rangeAtMost(PayloadDefect, .unsupported_depth, .truncated_mask, 1),
};

const png_defect_weights = [_]Weight{
    .value(PayloadDefect, .none, 6),
    .value(PayloadDefect, .broken_png_header, 1),
};

const entry_defect_weights = [_]Weight{
    .value(EntryDefect, .none, 30),
    .rangeAtMost(EntryDefect, .reserved, .width_mismatch, 1),
};

const header_defect_weights = [_]Weight{
    .value(HeaderDefect, .none, 20),
    .rangeAtMost(HeaderDefect, .too_short, .short_directory, 1),
};

const entry_count_weights = [_]Weight{
    .rangeAtMost(u8, 1, 6, 16),
    .rangeAtMost(u8, 1, directory_capacity, 1),
};

/// Cells around the generated sizes, and the extremes.
const cell_weights = [_]Weight{
    .rangeAtMost(u32, 0, max_dib_width + 1, 1 << 20),
    .rangeAtMost(u32, 0, max_entry_side + 1, 1 << 10),
    .value(u32, std.math.maxInt(u32), 1 << 10),
};

/// Sizes and offsets a rewritten entry takes: within the file, and the
/// extremes.
const entry_value_weights = [_]Weight{
    .rangeAtMost(u32, 0, file_capacity, 1 << 20),
    .value(u32, std.math.maxInt(u32), 1 << 30),
    .rangeAtMost(u32, 0, std.math.maxInt(u32), 1),
};

/// A payload this file generated: straight RGBA and its AND mask, both
/// top-down, with one defect.
const IcoPayload = struct {
    format: PayloadFormat,
    width: u32,
    height: u32,
    filter: FilterType,
    defect: PayloadDefect,
    pixels: [max_payload_pixels * 4]u8,
    mask: [max_dib_height * max_mask_stride]u8,
};

/// A directory entry: which payload it names, its defect and the width it
/// declares, 256 standing for the byte 0.
const IcoEntry = struct {
    payload: u8,
    defect: EntryDefect,
    declared_width: u16,
    amount: u32,
};

const GeneratedIco = struct {
    payloads: [max_payloads]IcoPayload,
    payload_count: u8,
    entries: [directory_capacity]IcoEntry,
    entry_count: u8,
    header_defect: HeaderDefect,
    header_amount: u32,
};

const IcoFile = struct {
    bytes: [file_capacity]u8,
    len: usize,

    fn written(self: *const IcoFile) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// What an entry does to decoding before selection.
const EntryVerdict = enum {
    fatal,
    skipped,
    candidate,
};

/// What `decode` owes a generated file: an error, or the payload whose
/// pixels it returns.
const IcoExpectation = union(enum) {
    rejected: anyerror,
    image: u8,
};

/// What decoding one input produced.
const IcoTrial = struct {
    case: IcoCase,
    outcome: ?anyerror,
    failed_allocation: bool,
};

const IcoDecoding = struct {
    outcome: ?anyerror,
    allocations: usize,
};

/// A seed's Smith input and what replaying it must produce.
const IcoSeed = struct {
    input: []const u8,
    trial: IcoTrial,
};

/// `len` bytes counting up from `start`, for seed pixels and masks.
fn pattern(comptime len: usize, comptime start: u8) []const u8 {
    comptime {
        @setEvalBranchQuota(len * 4);
        var bytes: [len]u8 = undefined;
        for (&bytes, 0..) |*byte, index| {
            byte.* = start +% @as(u8, @truncate(index *% 37));
        }

        const constant = bytes;
        return &constant;
    }
}

/// A DIB payload with an alpha channel and no defect.
fn dibInput(comptime width: u32, comptime height: u32, comptime alpha: AlphaSource, comptime defect: PayloadDefect) []const u8 {
    const stride = ((width + 31) / 32) * 4;
    return seed.input(&.{
        seed.tag(PayloadFormat.dib),
        seed.int(width),
        seed.int(height),
        seed.bytes(pattern(width * height * 4, 1)),
        seed.tag(alpha),
        seed.bytes(pattern(stride * height, 3)),
        seed.tag(defect),
    });
}

fn pngInput(comptime width: u32, comptime height: u32, comptime defect: PayloadDefect) []const u8 {
    return seed.input(&.{
        seed.tag(PayloadFormat.png),
        seed.int(width),
        seed.int(height),
        seed.bytes(pattern(width * height * 4, 5)),
        seed.tag(FilterType.paeth),
        seed.tag(defect),
    });
}

fn entryInput(comptime payload: u8, comptime defect: EntryDefect, comptime amount: u32) []const u8 {
    return switch (defect) {
        .none => seed.input(&.{
            seed.int(payload),
            seed.tag(defect),
        }),
        else => seed.input(&.{
            seed.int(payload),
            seed.tag(defect),
            seed.int(amount),
        }),
    };
}

const telar_ico = imaging.testing.telar_ico;

const ico_seeds = [_]IcoSeed{
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            dibInput(2, 2, .alpha, .none),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(16) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(3) }),
            dibInput(8, 8, .mask, .none),
            pngInput(16, 16, .none),
            dibInput(33, 3, .mask, .none),
            seed.input(&.{seed.int(3)}),
            entryInput(0, .none, 0),
            entryInput(1, .none, 0),
            entryInput(2, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(10) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(2) }),
            dibInput(4, 4, .alpha, .unsupported_depth),
            dibInput(5, 5, .alpha, .compressed),
            seed.input(&.{seed.int(2)}),
            entryInput(0, .none, 0),
            entryInput(1, .width_mismatch, 7),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.UnsupportedIco,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            pngInput(4, 4, .broken_png_header),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.InvalidPngData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            pngInput(4, 4, .none),
            seed.input(&.{seed.int(2)}),
            entryInput(0, .width_mismatch, max_entry_side),
            entryInput(0, .reserved, 1),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.InvalidIcoData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            pngInput(4, 4, .none),
            seed.input(&.{seed.int(2)}),
            entryInput(0, .width_mismatch, max_entry_side),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.InvalidIcoData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            dibInput(3, 2, .mask, .truncated_mask),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.InvalidIcoData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            dibInput(2, 2, .alpha, .none),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.too_many_entries), seed.int(directory_capacity + 1), seed.int(16) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.UnsupportedIco,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            dibInput(2, 2, .alpha, .none),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.bad_magic), seed.int(2), seed.int(16) }),
        }),
        .trial = .{
            .case = .generated,
            .outcome = error.NotIco,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.mutated), seed.int(1) }),
            dibInput(2, 2, .alpha, .none),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(16) }),
            seed.input(&.{ seed.int(1), seed.tag(IcoMutation.rewrite_entry), seed.int(0), seed.tag(EntryField.offset), seed.int(std.math.maxInt(u32)) }),
        }),
        .trial = .{
            .case = .mutated,
            .outcome = error.InvalidIcoData,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.input(&.{
            seed.tag(IcoCase.raw),
            seed.sliceLength(telar_ico.len),
            seed.bytes(telar_ico),
            seed.int(32),
        }),
        .trial = .{
            .case = .raw,
            .outcome = null,
            .failed_allocation = false,
        },
    },
    .{
        .input = seed.join(&.{
            seed.input(&.{ seed.tag(IcoCase.generated), seed.int(1) }),
            pngInput(4, 4, .none),
            seed.input(&.{seed.int(1)}),
            entryInput(0, .none, 0),
            seed.input(&.{ seed.tag(HeaderDefect.none), seed.int(4), seed.int(1), seed.int(2) }),
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
const ico_corpus = corpus: {
    var entries: [ico_seeds.len][]const u8 = undefined;
    for (ico_seeds, &entries) |ico_seed, *entry| {
        entry.* = ico_seed.input;
    }

    break :corpus entries;
};

fn maskStride(width: u32) usize {
    return ((width + 31) / 32) * 4;
}

fn generatePayload(smith: *Smith, payload: *IcoPayload) void {
    payload.format = smith.value(PayloadFormat);
    const max_width: u32 = if (payload.format == .dib) max_dib_width else max_png_side;
    const max_height: u32 = if (payload.format == .dib) max_dib_height else max_png_side;
    payload.width = smith.valueRangeAtMost(u32, 1, max_width);
    payload.height = smith.valueRangeAtMost(u32, 1, max_height);
    smith.bytes(payload.pixels[0 .. payload.width * payload.height * 4]);
    payload.filter = .none;

    if (payload.format == .png) {
        payload.filter = smith.value(FilterType);
        payload.defect = smith.valueWeighted(PayloadDefect, &png_defect_weights);
        return;
    }

    if (smith.value(AlphaSource) == .mask) {
        for (0..payload.width * payload.height) |index| {
            payload.pixels[index * 4 + 3] = 0;
        }
    }

    smith.bytes(payload.mask[0 .. maskStride(payload.width) * payload.height]);
    payload.defect = smith.valueWeighted(PayloadDefect, &dib_defect_weights);
}

fn generateIco(smith: *Smith, generated: *GeneratedIco) void {
    generated.payload_count = smith.valueRangeAtMost(u8, 1, max_payloads);
    for (generated.payloads[0..generated.payload_count]) |*payload| {
        generatePayload(smith, payload);
    }

    generated.entry_count = smith.valueWeighted(u8, &entry_count_weights);
    const directory_end: u32 = directory_head_bytes + @as(u32, generated.entry_count) * entry_bytes;
    for (generated.entries[0..generated.entry_count]) |*entry| {
        entry.payload = @intCast(smith.index(generated.payload_count));
        entry.defect = smith.valueWeighted(EntryDefect, &entry_defect_weights);
        entry.declared_width = @intCast(generated.payloads[entry.payload].width);
        entry.amount = switch (entry.defect) {
            .none => 0,
            .reserved => smith.valueRangeAtMost(u32, 1, std.math.maxInt(u8)),
            .offset_before_directory => smith.valueRangeLessThan(u32, 0, directory_end),
            .offset_past_end, .size_past_end => smith.valueRangeAtMost(u32, 1, std.math.maxInt(u32)),
            .width_mismatch => smith.valueRangeAtMost(u32, 1, max_entry_side),
        };
        if (entry.defect == .width_mismatch) {
            entry.declared_width = if (entry.amount == entry.declared_width) entry.declared_width % max_entry_side + 1 else @intCast(entry.amount);
        }
    }

    generated.header_defect = smith.valueWeighted(HeaderDefect, &header_defect_weights);
    generated.header_amount = switch (generated.header_defect) {
        .none, .no_entries => 0,
        .too_short => smith.valueRangeLessThan(u32, 0, directory_head_bytes),
        .bad_magic => smith.valueRangeLessThan(u32, 0, magic.len),
        .too_many_entries => smith.valueRangeAtMost(u32, directory_capacity + 1, std.math.maxInt(u16)),
        .short_directory => smith.valueRangeLessThan(u32, directory_head_bytes, directory_end),
    };
}

fn writeBitmapField(bytes: []u8, field: BitmapField, comptime T: type, value: T) void {
    std.mem.writeInt(T, bytes[@intFromEnum(field)..][0..@sizeOf(T)], value, .little);
}

/// A 32-bit BITMAPINFOHEADER image, bottom-up BGRA then the bottom-up AND
/// mask, with the payload's defect written in.
fn writeDib(payload: *const IcoPayload, out: []u8) usize {
    const header = out[0..bitmap_header_bytes];
    @memset(header, 0);
    writeBitmapField(header, .header_size, u32, bitmap_header_bytes);
    writeBitmapField(header, .width, u32, payload.width);
    writeBitmapField(header, .height, u32, if (payload.defect == .wrong_height) payload.height else payload.height * 2);
    writeBitmapField(header, .planes, u16, if (payload.defect == .wrong_planes) 2 else 1);
    writeBitmapField(header, .bit_count, u16, if (payload.defect == .unsupported_depth) unsupported_bit_count else 32);
    writeBitmapField(header, .compression, u32, if (payload.defect == .compressed) bitfields_compression else 0);
    writeBitmapField(header, .colors_used, u32, if (payload.defect == .color_table) unsupported_colors_used else 0);

    const width: usize = payload.width;
    const height: usize = payload.height;
    const bitmap = out[bitmap_header_bytes..][0 .. width * height * 4];
    for (0..height) |row| {
        const source_row = height - 1 - row;
        for (0..width) |column| {
            const rgba = payload.pixels[(source_row * width + column) * 4 ..][0..4];
            bitmap[(row * width + column) * 4 ..][0..4].* = .{ rgba[2], rgba[1], rgba[0], rgba[3] };
        }
    }

    const stride = maskStride(payload.width);
    const mask = out[bitmap_header_bytes + bitmap.len ..][0 .. stride * height];
    for (0..height) |row| {
        @memcpy(mask[row * stride ..][0..stride], payload.mask[(height - 1 - row) * stride ..][0..stride]);
    }

    const len = bitmap_header_bytes + bitmap.len + mask.len;
    return if (payload.defect == .truncated_mask) len - 1 else len;
}

fn writePng(payload: *const IcoPayload, out: []u8) !usize {
    const gpa = std.testing.allocator;
    const bytes = try png.encodeForTest(
        gpa,
        .{
            .header = .{
                .width = payload.width,
                .height = payload.height,
                .color = .rgba,
            },
            .filter = @intFromEnum(payload.filter),
        },
        payload.pixels[0 .. payload.width * payload.height * 4],
    );
    defer gpa.free(bytes);

    @memcpy(out[0..bytes.len], bytes);
    if (payload.defect == .broken_png_header) {
        out[png_ihdr_crc_offset] ^= 1;
    }

    return bytes.len;
}

/// Lays out the directory, then the payloads in order, then writes each
/// entry's defect and the header defect.
fn writeIco(generated: *const GeneratedIco, file: *IcoFile) !void {
    const directory_end = directory_head_bytes + @as(usize, generated.entry_count) * entry_bytes;
    var offsets: [max_payloads]u32 = undefined;
    var sizes: [max_payloads]u32 = undefined;
    var end = directory_end;
    for (generated.payloads[0..generated.payload_count], offsets[0..generated.payload_count], sizes[0..generated.payload_count]) |*payload, *offset, *size| {
        const len = switch (payload.format) {
            .dib => writeDib(payload, file.bytes[end..]),
            .png => try writePng(payload, file.bytes[end..]),
        };
        offset.* = @intCast(end);
        size.* = @intCast(len);
        end += len;
    }

    file.len = end;
    @memcpy(file.bytes[0..magic.len], magic);
    std.mem.writeInt(u16, file.bytes[magic.len..directory_head_bytes], generated.entry_count, .little);

    const total: u32 = @intCast(end);
    for (generated.entries[0..generated.entry_count], 0..) |entry, index| {
        const bytes = file.bytes[directory_head_bytes + index * entry_bytes ..][0..entry_bytes];
        const payload = &generated.payloads[entry.payload];
        @memset(bytes, 0);
        bytes[@intFromEnum(EntryField.width)] = @truncate(entry.declared_width);
        bytes[@intFromEnum(EntryField.height)] = @intCast(payload.height);

        var offset = offsets[entry.payload];
        var size = sizes[entry.payload];
        switch (entry.defect) {
            .none, .width_mismatch => {},
            .reserved => bytes[@intFromEnum(EntryField.reserved)] = @intCast(entry.amount),
            .offset_before_directory => offset = entry.amount,
            .offset_past_end => offset = total +| entry.amount,
            .size_past_end => size = (total - offset) +| entry.amount,
        }

        writeEntryField(bytes, .size, size);
        writeEntryField(bytes, .offset, offset);
    }

    switch (generated.header_defect) {
        .none => {},
        .too_short, .short_directory => file.len = generated.header_amount,
        .bad_magic => file.bytes[generated.header_amount] ^= std.math.maxInt(u8),
        .no_entries => std.mem.writeInt(u16, file.bytes[magic.len..directory_head_bytes], 0, .little),
        .too_many_entries => std.mem.writeInt(u16, file.bytes[magic.len..directory_head_bytes], @intCast(generated.header_amount), .little),
    }
}

fn writeEntryField(entry: []u8, field: EntryField, value: u32) void {
    std.mem.writeInt(u32, entry[@intFromEnum(field)..][0..4], value, .little);
}

/// How `decode` treats an entry before selection, in the order it checks:
/// bounds, the reserved byte, a PNG signature, an unsupported bitmap, then
/// the bitmap's dimensions, planes and length.
fn entryVerdict(generated: *const GeneratedIco, entry: IcoEntry) EntryVerdict {
    switch (entry.defect) {
        .reserved, .offset_before_directory, .offset_past_end, .size_past_end => return .fatal,
        .none, .width_mismatch => {},
    }

    if (generated.payloads[entry.payload].format == .png) {
        return .candidate;
    }

    switch (generated.payloads[entry.payload].defect) {
        .unsupported_depth, .compressed, .color_table => return .skipped,
        .wrong_planes, .wrong_height, .truncated_mask => return .fatal,
        .none, .broken_png_header => {},
    }

    return if (entry.defect == .width_mismatch) .fatal else .candidate;
}

/// The side selection compares: the shorter of the declared width and the
/// payload's height.
fn entrySide(generated: *const GeneratedIco, entry: IcoEntry) u32 {
    return @min(entry.declared_width, generated.payloads[entry.payload].height);
}

/// The entry `decode` picks among candidates: the first with the smallest
/// side covering `cell`, or when none covers it, the first with the largest
/// side.
fn selectEntry(generated: *const GeneratedIco, cell: u32) ?usize {
    var covering: ?usize = null;
    var largest: ?usize = null;
    for (generated.entries[0..generated.entry_count], 0..) |entry, index| {
        if (entryVerdict(generated, entry) != .candidate) {
            continue;
        }

        const side = entrySide(generated, entry);
        if (side >= cell and (covering == null or side < entrySide(generated, generated.entries[covering.?]))) {
            covering = index;
        }

        if (largest == null or side > entrySide(generated, generated.entries[largest.?])) {
            largest = index;
        }
    }

    return covering orelse largest;
}

/// What `decode` owes a generated file, computed from its generation.
fn expectedIco(generated: *const GeneratedIco, cell: u32) IcoExpectation {
    switch (generated.header_defect) {
        .too_short, .bad_magic => return .{ .rejected = error.NotIco },
        .no_entries, .too_many_entries => return .{ .rejected = error.UnsupportedIco },
        .short_directory => return .{ .rejected = error.InvalidIcoData },
        .none => {},
    }

    for (generated.entries[0..generated.entry_count]) |entry| {
        if (entryVerdict(generated, entry) == .fatal) {
            return .{ .rejected = error.InvalidIcoData };
        }
    }

    const selected = generated.entries[selectEntry(generated, cell) orelse return .{ .rejected = error.UnsupportedIco }];
    const payload = &generated.payloads[selected.payload];
    if (payload.defect == .broken_png_header) {
        return .{ .rejected = error.InvalidPngData };
    }

    if (selected.defect == .width_mismatch) {
        return .{ .rejected = error.InvalidIcoData };
    }

    return .{ .image = selected.payload };
}

/// The straight RGBA a payload decodes to: its pixels, with a DIB whose
/// alpha channel is empty taking alpha from the mask instead.
fn expectedPixels(payload: *const IcoPayload, pixels: []u8) void {
    const count = payload.width * payload.height;
    @memcpy(pixels, payload.pixels[0 .. count * 4]);
    if (payload.format == .png) {
        return;
    }

    for (0..count) |index| {
        if (pixels[index * 4 + 3] != 0) {
            return;
        }
    }

    const stride = maskStride(payload.width);
    for (0..payload.height) |row| {
        for (0..payload.width) |column| {
            const hidden = payload.mask[row * stride + column / 8] & (@as(u8, leftmost_mask_bit) >> @intCast(column % 8)) != 0;
            pixels[(row * payload.width + column) * 4 + 3] = if (hidden) 0 else std.math.maxInt(u8);
        }
    }
}

fn mutate(smith: *Smith, file: *IcoFile) void {
    const count = smith.valueRangeAtMost(u8, 1, max_mutations);
    for (0..count) |_| {
        if (file.len == 0) {
            return;
        }

        switch (smith.value(IcoMutation)) {
            .flip_byte => file.bytes[smith.index(file.len)] ^= smith.valueRangeAtMost(u8, 1, std.math.maxInt(u8)),
            .set_byte => file.bytes[smith.index(file.len)] = smith.value(u8),
            .truncate => file.len = smith.index(file.len),
            .rewrite_entry => rewriteEntry(smith, file),
        }
    }
}

fn rewriteEntry(smith: *Smith, file: *IcoFile) void {
    const index = smith.index(directory_capacity);
    const field = smith.value(EntryField);
    const start = directory_head_bytes + index * entry_bytes;
    if (start + entry_bytes > file.len) {
        return;
    }

    const bytes = file.bytes[start..][0..entry_bytes];
    switch (field) {
        .width, .height, .reserved => bytes[@intFromEnum(field)] = smith.value(u8),
        .size, .offset => writeEntryField(bytes, field, smith.valueWeighted(u32, &entry_value_weights)),
    }
}

/// The error `decode` owes `bytes` from its header alone, in the order it
/// checks: length and magic, the entry count, then the directory's length.
fn expectedHeaderRejection(bytes: []const u8) ?anyerror {
    if (bytes.len < directory_head_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic)) {
        return error.NotIco;
    }

    const count = std.mem.readInt(u16, bytes[magic.len..directory_head_bytes], .little);
    if (count == 0 or count > directory_capacity) {
        return error.UnsupportedIco;
    }

    if (bytes.len < directory_head_bytes + @as(usize, count) * entry_bytes) {
        return error.InvalidIcoData;
    }

    return null;
}

/// The width and height an entry of a well-formed directory declares, 0
/// standing for 256.
fn declaresSize(bytes: []const u8, width: u32, height: u32) bool {
    const count = std.mem.readInt(u16, bytes[magic.len..directory_head_bytes], .little);
    for (0..count) |index| {
        const entry = bytes[directory_head_bytes + index * entry_bytes ..][0..entry_bytes];
        const declared_width: u32 = if (entry[@intFromEnum(EntryField.width)] == 0) max_entry_side else entry[@intFromEnum(EntryField.width)];
        const declared_height: u32 = if (entry[@intFromEnum(EntryField.height)] == 0) max_entry_side else entry[@intFromEnum(EntryField.height)];
        if (declared_width == width and declared_height == height) {
            return true;
        }
    }

    return false;
}

/// Rejections a mutated file may meet past its header.
fn isIcoRejection(err: anyerror) bool {
    return switch (err) {
        error.UnsupportedIco, error.InvalidIcoData, error.NotPng, error.InvalidPngData, error.PngTooLarge => true,
        else => false,
    };
}

/// Decodes `bytes` once without failing allocations. A header rejection
/// must be exactly the one owed and allocate nothing. With an expectation,
/// the outcome and pixels must be exactly it; without one, a rejection comes
/// from the ICO and PNG error sets and an image has the size a directory
/// entry declares, four bytes per pixel.
fn expectDecoding(bytes: []const u8, cell: u32, expectation: ?IcoExpectation, generated: *const GeneratedIco) !IcoDecoding {
    var failing: FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    const rejection = expectedHeaderRejection(bytes);

    const outcome: ?anyerror = if (ico.decode(gpa, bytes, cell)) |decoded| accepted: {
        var image = decoded;
        defer image.deinit(gpa);

        try std.testing.expectEqual(null, rejection);
        try std.testing.expect(image.width >= 1 and image.width <= max_entry_side);
        try std.testing.expect(image.height >= 1 and image.height <= max_entry_side);
        try std.testing.expectEqual(@as(usize, image.width) * image.height * 4, image.pixels.len);
        try std.testing.expect(declaresSize(bytes, image.width, image.height));
        if (expectation) |owed| {
            const payload = &generated.payloads[try expectImage(owed)];
            var pixels: [max_payload_pixels * 4]u8 = undefined;
            expectedPixels(payload, pixels[0 .. payload.width * payload.height * 4]);
            try std.testing.expectEqual(payload.width, image.width);
            try std.testing.expectEqual(payload.height, image.height);
            try std.testing.expectEqualSlices(u8, pixels[0 .. payload.width * payload.height * 4], image.pixels);
        }

        break :accepted null;
    } else |err| rejected: {
        if (rejection) |owed| {
            try std.testing.expectEqual(owed, err);
            try std.testing.expectEqual(0, failing.allocations);
        } else if (expectation) |owed| {
            try std.testing.expectEqual(owed, IcoExpectation{ .rejected = err });
        } else {
            try std.testing.expect(isIcoRejection(err));
        }

        break :rejected err;
    };

    try seed.expectReleased(&failing);
    return .{
        .outcome = outcome,
        .allocations = failing.allocations,
    };
}

fn expectImage(expectation: IcoExpectation) !u8 {
    return switch (expectation) {
        .image => |payload| payload,
        .rejected => error.UnexpectedImage,
    };
}

/// Maybe fails one of the `allocations` the clean decode made, which must
/// be `OutOfMemory` with everything released.
fn expectAllocationFailure(smith: *Smith, bytes: []const u8, cell: u32, allocations: usize) !bool {
    if (allocations == 0 or !smith.valueWeighted(bool, &seed.failure_weights)) {
        return false;
    }

    var failing: FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = smith.index(allocations),
    });
    const gpa = failing.allocator();
    if (ico.decode(gpa, bytes, cell)) |decoded| {
        var image = decoded;
        image.deinit(gpa);
        return error.AllocationFailureIgnored;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    try seed.expectReleased(&failing);
    return true;
}

/// A broken property panics so the fuzzer keeps the input; Wuffs warnings
/// are muted as in `png_fuzz_test.zig`.
fn decodeFuzzedIco(_: void, smith: *Smith) anyerror!void {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;

    _ = expectIcoDecoding(smith) catch |err| std.debug.panic("ICO property failed: {t}", .{err});
}

fn expectIcoDecoding(smith: *Smith) !IcoTrial {
    const case = smith.value(IcoCase);
    var generated: GeneratedIco = undefined;
    var file: IcoFile = undefined;
    var expectation: ?IcoExpectation = null;
    if (case == .raw) {
        generated.payload_count = 0;
        file.len = smith.slice(&file.bytes);
    } else {
        generateIco(smith, &generated);
        try writeIco(&generated, &file);
    }

    const cell = smith.valueWeighted(u32, &cell_weights);
    switch (case) {
        .generated => expectation = expectedIco(&generated, cell),
        .mutated => mutate(smith, &file),
        .raw => {},
    }

    const decoding = try expectDecoding(file.written(), cell, expectation, &generated);
    return .{
        .case = case,
        .outcome = decoding.outcome,
        .failed_allocation = try expectAllocationFailure(smith, file.written(), cell, decoding.allocations),
    };
}

fn replay(input: []const u8) !IcoTrial {
    var smith: Smith = .{ .in = input };
    return expectIcoDecoding(&smith);
}

fn generateFromSeed(index: usize, generated: *GeneratedIco, file: *IcoFile) !void {
    var smith: Smith = .{
        .in = ico_corpus[index],
    };
    try std.testing.expectEqual(IcoCase.generated, smith.value(IcoCase));
    generateIco(&smith, generated);
    try writeIco(generated, file);
}

test "every ico fuzz seed reaches its case and outcome" {
    for (ico_seeds) |ico_seed| {
        try std.testing.expectEqual(ico_seed.trial, try replay(ico_seed.input));
    }

    try std.testing.expectEqual(IcoTrial{
        .case = .generated,
        .outcome = null,
        .failed_allocation = false,
    }, try replay(""));
}

test "cells pick the smallest covering entry, else the largest, across mask strides" {
    var generated: GeneratedIco = undefined;
    var file: IcoFile = undefined;
    try generateFromSeed(1, &generated, &file);

    // Sides 8, 16 and 3 (a 33 x 3 bitmap with two mask words per row).
    for ([_]u32{ 0, 3, 4, 8, 9, 16, 17, max_entry_side }, [_]u8{ 2, 2, 0, 0, 1, 1, 1, 1 }) |cell, payload| {
        try std.testing.expectEqual(IcoExpectation{ .image = payload }, expectedIco(&generated, cell));
        _ = try expectDecoding(file.written(), cell, expectedIco(&generated, cell), &generated);
    }
}

test "directory bounds are checked at the 64-entry limit and at 256-pixel entries" {
    var generated: GeneratedIco = undefined;
    var file: IcoFile = undefined;
    try generateFromSeed(0, &generated, &file);

    // 64 entries naming one 2 x 2 bitmap decode; a 65th is unsupported.
    const payload_len = file.len - directory_head_bytes - entry_bytes;
    var wide: IcoFile = undefined;
    const directory_end = directory_head_bytes + directory_capacity * entry_bytes;
    @memcpy(wide.bytes[0..directory_head_bytes], file.bytes[0..directory_head_bytes]);
    std.mem.writeInt(u16, wide.bytes[magic.len..directory_head_bytes], directory_capacity, .little);
    for (0..directory_capacity) |index| {
        const entry = wide.bytes[directory_head_bytes + index * entry_bytes ..][0..entry_bytes];
        @memcpy(entry, file.bytes[directory_head_bytes..][0..entry_bytes]);
        writeEntryField(entry, .offset, directory_end);
    }

    @memcpy(wide.bytes[directory_end..][0..payload_len], file.bytes[directory_head_bytes + entry_bytes ..][0..payload_len]);
    wide.len = directory_end + payload_len;
    var image = try ico.decode(std.testing.allocator, wide.written(), 2);
    image.deinit(std.testing.allocator);

    std.mem.writeInt(u16, wide.bytes[magic.len..directory_head_bytes], directory_capacity + 1, .little);
    var failing: FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.UnsupportedIco, ico.decode(failing.allocator(), wide.written(), 2));

    // An entry whose width byte 0 declares 256, over a bitmap header that
    // agrees, needs 256 x 2 pixels and mask rows the 2 x 2 payload lacks: it
    // is rejected before its pixels are allocated.
    file.bytes[directory_head_bytes + @intFromEnum(EntryField.width)] = 0;
    writeBitmapField(file.bytes[directory_head_bytes + entry_bytes ..], .width, u32, max_entry_side);
    try std.testing.expectError(error.InvalidIcoData, ico.decode(failing.allocator(), file.written(), 2));
    try std.testing.expectEqual(0, failing.allocations);
    try std.testing.expectEqual(false, failing.has_induced_failure);
}

test "a PNG entry past the ICO limit is rejected before any allocation" {
    var generated: GeneratedIco = undefined;
    var file: IcoFile = undefined;
    try generateFromSeed(3, &generated, &file);

    // Seed 3 breaks the IHDR CRC; restore it with a width past the ICO limit.
    const ihdr = file.bytes[directory_head_bytes + entry_bytes + png_ihdr_offset ..];
    const data_end = png_chunk_head_bytes + png_ihdr_data_bytes;
    std.mem.writeInt(u32, ihdr[png_chunk_head_bytes..][0..4], max_entry_side + 1, .big);
    std.mem.writeInt(u32, ihdr[data_end..][0..4], std.hash.Crc32.hash(ihdr[4..data_end]), .big);

    var failing: FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.PngTooLarge, ico.decode(failing.allocator(), file.written(), 4));
    try std.testing.expectEqual(false, failing.has_induced_failure);
}

test "mixed ICO directories release every allocation failure" {
    for ([_]usize{ 0, 1, 11 }) |index| {
        var generated: GeneratedIco = undefined;
        var file: IcoFile = undefined;
        try generateFromSeed(index, &generated, &file);
        for ([_]u32{ 1, 10, 32 }) |cell| {
            try std.testing.checkAllAllocationFailures(
                std.testing.allocator,
                expectOwedDecoding,
                .{
                    file.written(),
                    cell,
                    &generated,
                },
            );
        }
    }
}

fn expectOwedDecoding(gpa: std.mem.Allocator, bytes: []const u8, cell: u32, generated: *const GeneratedIco) !void {
    var image = try ico.decode(gpa, bytes, cell);
    defer image.deinit(gpa);

    const payload = &generated.payloads[try expectImage(expectedIco(generated, cell))];
    var pixels: [max_payload_pixels * 4]u8 = undefined;
    expectedPixels(payload, pixels[0 .. payload.width * payload.height * 4]);
    try std.testing.expectEqualSlices(u8, pixels[0 .. payload.width * payload.height * 4], image.pixels);
}

test "fuzz ico decoding" {
    try std.testing.fuzz({}, decodeFuzzedIco, .{
        .corpus = &ico_corpus,
    });
}
