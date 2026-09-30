//! Native fuzzing of text metadata, the row flags and hyperlink runs a frame
//! carries beside its cells.
//!
//! This root runs only through `zig build test-fuzz-frames-metadata`; no
//! suite imports it. One target decodes arbitrary bytes for a fuzzed screen
//! size beside a reference validator written from the format, and rebuilds
//! every accepted replacement with `Builder`. The other builds legal
//! replacements and decodes them. `View.trusted` is only ever reached
//! through `View.decode` or `Builder.finish`.

const std = @import("std");
const Builder = @import("Builder.zig");
const LinkRun = @import("LinkRun.zig");
const limits = @import("limits.zig");
const RowFlags = @import("RowFlags.zig").RowFlags;
const View = @import("View.zig");
const Smith = std.testing.Smith;

/// Screen sizes the targets decode for; 0 reaches the degenerate sizes.
const max_fuzzed_cols = 64;
const max_fuzzed_rows = 16;
/// Room for a URI one byte over `limits.max_uri_bytes`, so that bound is
/// reachable, and for `limits.max_links` one-byte URIs.
const payload_capacity = 2 * limits.max_uri_bytes;
const scratch_capacity = limits.capacity(max_fuzzed_rows);
const max_generated_links = 8;
const max_generated_uri_bytes = 64;
const max_generated_runs = 32;
/// A wide glyph and the padding it displaces.
const wide_glyph_columns = 2;

const MetadataError = error{ TextMetadataTooLarge, Truncated, TrailingBytes, InvalidTextMetadata };

/// The error `View.decode` owes `bytes` for a screen of `size`, in the order
/// the format is read: total size, header, counts, row flags, the sections
/// the counts announce, nothing after them, contiguous URIs, then sorted
/// row-local runs naming known links.
fn expectedMetadataError(bytes: []const u8, size: [2]u16) ?MetadataError {
    const cols = size[0];
    const rows = size[1];
    if (bytes.len > limits.capacity(rows)) {
        return error.TextMetadataTooLarge;
    }

    if (bytes.len == 0) {
        return error.Truncated;
    }

    const status = std.enums.fromInt(limits.Status, bytes[0]) orelse return error.InvalidTextMetadata;
    if (bytes.len < limits.header_size) {
        return error.Truncated;
    }

    const row_count = std.mem.readInt(u16, bytes[1..3], .little);
    const link_count = std.mem.readInt(u16, bytes[3..5], .little);
    const run_count = std.mem.readInt(u16, bytes[5..7], .little);
    const uri_length = std.mem.readInt(u32, bytes[7..11], .little);
    if (row_count != rows or link_count > limits.max_links or run_count > limits.max_runs or uri_length > limits.max_total_uri_bytes) {
        return error.InvalidTextMetadata;
    }

    if (status == .omitted and (link_count != 0 or run_count != 0 or uri_length != 0)) {
        return error.InvalidTextMetadata;
    }

    const links_start = limits.header_size + @as(usize, row_count);
    if (bytes.len < links_start) {
        return error.Truncated;
    }

    for (bytes[limits.header_size..links_start]) |byte| {
        const flags: RowFlags = @bitCast(byte);
        if (flags.reserved != 0 or (flags.wide_padding and (!flags.wrap or cols < wide_glyph_columns))) {
            return error.InvalidTextMetadata;
        }
    }

    const runs_start = links_start + @as(usize, link_count) * limits.link_size;
    const uris_start = runs_start + @as(usize, run_count) * limits.run_size;
    const end = uris_start + uri_length;
    if (bytes.len < end) {
        return error.Truncated;
    }

    if (bytes.len > end) {
        return error.TrailingBytes;
    }

    var uri_end: usize = 0;
    for (0..link_count) |index| {
        const entry = bytes[links_start + index * limits.link_size ..][0..limits.link_size];
        const offset = std.mem.readInt(u32, entry[0..4], .little);
        const length = std.mem.readInt(u16, entry[4..6], .little);
        if (offset != uri_end or length == 0 or length > limits.max_uri_bytes or uri_end + length > uri_length) {
            return error.InvalidTextMetadata;
        }

        uri_end += length;
    }

    if (uri_end != uri_length) {
        return error.InvalidTextMetadata;
    }

    const cell_count = @as(u64, cols) * rows;
    var previous_end: u64 = 0;
    for (0..run_count) |index| {
        const run = readRun(bytes[runs_start..uris_start], index);
        const run_end = @as(u64, run.start) + run.len;
        if (run.len == 0 or run.start < previous_end or run_end > cell_count or run.link_index >= link_count or run_end > std.math.maxInt(u32)) {
            return error.InvalidTextMetadata;
        }

        if (run.start / cols != (run_end - 1) / cols) {
            return error.InvalidTextMetadata;
        }

        previous_end = run_end;
    }

    return null;
}

fn readRun(run_bytes: []const u8, index: usize) LinkRun {
    const entry = run_bytes[index * limits.run_size ..][0..limits.run_size];
    return .{
        .start = std.mem.readInt(u32, entry[0..4], .little),
        .len = std.mem.readInt(u32, entry[4..8], .little),
        .link_index = std.mem.readInt(u16, entry[8..10], .little),
    };
}

/// The run covering `cell`, by a walk over every run.
fn runAt(run_bytes: []const u8, cell: u32) ?LinkRun {
    for (0..run_bytes.len / limits.run_size) |index| {
        const run = readRun(run_bytes, index);
        if (cell >= run.start and cell - run.start < run.len) {
            return run;
        }
    }

    return null;
}

fn isInside(inner: []const u8, outer: []const u8) bool {
    const start = @intFromPtr(inner.ptr);
    return start >= @intFromPtr(outer.ptr) and start + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

/// Every accessor of an accepted view stays inside its bytes and agrees
/// with a walk over the encoding: each link inside the URI bytes, each run
/// in order, `at` for every cell of the screen and one past it.
fn expectViewAccessors(view: View, size: [2]u16) !void {
    try std.testing.expectEqual(@as(usize, size[1]), view.rows.len);
    try std.testing.expect(isInside(view.uri_bytes, view.encoded));

    var uri_bytes: usize = 0;
    for (0..view.link_count) |index| {
        const uri = view.link(@intCast(index)).?;
        try std.testing.expect(isInside(uri, view.uri_bytes));
        try std.testing.expectEqual(@intFromPtr(view.uri_bytes.ptr) + uri_bytes, @intFromPtr(uri.ptr));
        uri_bytes += uri.len;
    }

    try std.testing.expectEqual(view.uri_bytes.len, uri_bytes);
    try std.testing.expectEqual(null, view.link(view.link_count));

    var runs = view.runs();
    for (0..view.run_count) |index| {
        try std.testing.expectEqual(readRun(view.run_bytes, index), runs.next().?);
    }

    try std.testing.expectEqual(null, runs.next());

    const cell_count = @as(u32, size[0]) * size[1];
    for (0..cell_count + 1) |cell| {
        try std.testing.expectEqual(runAt(view.run_bytes, @intCast(cell)), view.at(@intCast(cell)));
    }
}

/// Rebuilds an accepted view through `Builder`. The encoding admits one
/// byte string per replacement, so the rebuild must equal it exactly.
fn expectBuilderRebuilds(view: View) !void {
    var scratch: [scratch_capacity]u8 = undefined;
    const rows: u16 = @intCast(view.rows.len);
    var builder = Builder.init(&scratch, rows);
    for (view.rows, 0..) |flags, y| {
        builder.setRow(@intCast(y), flags);
    }

    for (0..view.link_count) |index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), try builder.addLink(view.link(@intCast(index)).?));
    }

    var runs = view.runs();
    while (runs.next()) |run| {
        try builder.addRun(run);
    }

    try std.testing.expectEqualSlices(u8, view.encoded, builder.finish(view.status).encoded);
}

/// A payload the decoding target starts from, the screen it is decoded for
/// and what `View.decode` answers; a null outcome is an accepted view.
const MetadataSeed = struct {
    cols: u16,
    rows: u16,
    payload: []const u8,
    outcome: ?MetadataError,
};

fn header(comptime status: u8, comptime rows: u16, comptime links: u16, comptime runs: u16, comptime uri_length: u32) [limits.header_size]u8 {
    var bytes: [limits.header_size]u8 = undefined;
    bytes[0] = status;
    std.mem.writeInt(u16, bytes[1..3], rows, .little);
    std.mem.writeInt(u16, bytes[3..5], links, .little);
    std.mem.writeInt(u16, bytes[5..7], runs, .little);
    std.mem.writeInt(u32, bytes[7..11], uri_length, .little);
    return bytes;
}

fn linkEntry(comptime offset: u32, comptime length: u16) [limits.link_size]u8 {
    var bytes: [limits.link_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], offset, .little);
    std.mem.writeInt(u16, bytes[4..6], length, .little);
    return bytes;
}

fn runEntry(comptime start: u32, comptime length: u32, comptime link_index: u16) [limits.run_size]u8 {
    var bytes: [limits.run_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], start, .little);
    std.mem.writeInt(u32, bytes[4..8], length, .little);
    std.mem.writeInt(u16, bytes[8..10], link_index, .little);
    return bytes;
}

fn rowFlags(comptime flags: RowFlags) u8 {
    return @bitCast(flags);
}

const complete = @intFromEnum(limits.Status.complete);
const omitted = @intFromEnum(limits.Status.omitted);
const fixture_uri = "https://example.test/a".*;
const fixture_rows = [_]u8{
    rowFlags(.{
        .wrap = true,
        .hyperlinks = true,
    }),
    rowFlags(.{
        .continuation = true,
        .hyperlinks = true,
    }),
};
const fixture_links = linkEntry(0, fixture_uri.len) ++ linkEntry(fixture_uri.len, fixture_uri.len);
const fixture_uris = fixture_uri ++ fixture_uri;

/// Two links to the same URI and three runs on a 4x2 screen, with `runs`
/// in place of the fixture's runs.
fn linkedFixture(comptime run_count: u16, comptime runs: []const u8) []const u8 {
    comptime {
        const bytes = header(complete, fixture_rows.len, 2, run_count, fixture_uris.len) ++ fixture_rows ++ fixture_links ++ runs[0..runs.len].* ++ fixture_uris;
        return &bytes;
    }
}

const fixture_runs = runEntry(0, 2, 0) ++ runEntry(3, 1, 1) ++ runEntry(4, 4, 0);
const linked_fixture = linkedFixture(3, &fixture_runs);
const one_byte_links = links: {
    @setEvalBranchQuota(100_000);
    var entries: [limits.max_links * limits.link_size]u8 = undefined;
    for (0..limits.max_links) |index| {
        entries[index * limits.link_size ..][0..limits.link_size].* = linkEntry(index, 1);
    }

    break :links entries;
};
const longest_uri = [_]u8{'u'} ** limits.max_uri_bytes;

const metadata_seeds = [_]MetadataSeed{
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(complete, 2, 0, 0, 0) ++ [_]u8{ 0, 0 }),
        .outcome = null,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linked_fixture,
        .outcome = null,
    },
    .{
        .cols = 2,
        .rows = 1,
        .payload = &(header(omitted, 1, 0, 0, 0) ++ [_]u8{rowFlags(.{
            .wrap = true,
            .wide_padding = true,
        })}),
        .outcome = null,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &(header(complete, 1, limits.max_links, 0, limits.max_links) ++ [_]u8{0} ++ one_byte_links ++ [_]u8{'x'} ** limits.max_links),
        .outcome = null,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &(header(complete, 1, 1, 1, limits.max_uri_bytes) ++ [_]u8{rowFlags(.{ .hyperlinks = true })} ++ linkEntry(0, limits.max_uri_bytes) ++ runEntry(0, 1, 0) ++ longest_uri),
        .outcome = null,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = "",
        .outcome = error.Truncated,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linked_fixture[0 .. limits.header_size - 1],
        .outcome = error.Truncated,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linked_fixture[0 .. linked_fixture.len - 1],
        .outcome = error.Truncated,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(linked_fixture[0..linked_fixture.len].* ++ [_]u8{0}),
        .outcome = error.TrailingBytes,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(omitted + 1, 2, 0, 0, 0) ++ [_]u8{ 0, 0 }),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 3,
        .payload = linked_fixture,
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(omitted, 2, 1, 0, 1) ++ [_]u8{ 0, 0 } ++ linkEntry(0, 1) ++ "x".*),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &header(complete, 1, limits.max_links + 1, 0, 0),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &header(complete, 1, 0, limits.max_runs + 1, 0),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &header(complete, 1, 0, 0, limits.max_total_uri_bytes + 1),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &(header(complete, 1, 1, 0, limits.max_uri_bytes + 1) ++ [_]u8{0} ++ linkEntry(0, limits.max_uri_bytes + 1) ++ longest_uri ++ "u".*),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 1,
        .payload = &(header(complete, 1, 0, 0, 0) ++ [_]u8{rowFlags(.{ .reserved = 1 })}),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 1,
        .payload = &(header(complete, 1, 0, 0, 0) ++ [_]u8{rowFlags(.{ .wide_padding = true })}),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 1,
        .rows = 1,
        .payload = &(header(complete, 1, 0, 0, 0) ++ [_]u8{rowFlags(.{
            .wrap = true,
            .wide_padding = true,
        })}),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(complete, 2, 1, 0, 2) ++ [_]u8{ 0, 0 } ++ linkEntry(1, 1) ++ "xy".*),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(complete, 2, 1, 0, 0) ++ [_]u8{ 0, 0 } ++ linkEntry(0, 0)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = &(header(complete, 2, 1, 0, 2) ++ [_]u8{ 0, 0 } ++ linkEntry(0, 1) ++ "xy".*),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(1, &runEntry(0, 0, 0)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(2, &(runEntry(0, 2, 0) ++ runEntry(1, 1, 1))),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(2, &(runEntry(4, 1, 0) ++ runEntry(0, 1, 1))),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(1, &runEntry(3, 2, 0)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(1, &runEntry(7, 2, 0)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(1, &runEntry(std.math.maxInt(u32), 1, 0)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 4,
        .rows = 2,
        .payload = linkedFixture(1, &runEntry(0, 1, 2)),
        .outcome = error.InvalidTextMetadata,
    },
    .{
        .cols = 0,
        .rows = 2,
        .payload = linked_fixture,
        .outcome = error.InvalidTextMetadata,
    },
};

/// The seeds in `std.testing.Smith` input form: little-endian u64 columns
/// and rows, then a slice as a little-endian u32 length and its bytes. A
/// crash the fuzzer saves has the same form, so it can join this corpus as
/// it is.
const metadata_corpus = corpus: {
    @setEvalBranchQuota(100_000);
    var entries: [metadata_seeds.len][]const u8 = undefined;
    for (metadata_seeds, &entries) |seed, *entry| {
        entry.* = smithInput(seed.cols, seed.rows, seed.payload);
    }

    break :corpus entries;
};

fn smithInput(comptime cols: u64, comptime rows: u64, comptime payload: []const u8) []const u8 {
    comptime {
        var size: [2 * @sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, size[0..8], cols, .little);
        std.mem.writeInt(u64, size[8..16], rows, .little);
        var length: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &length, payload.len, .little);
        const entry = size ++ length ++ payload[0..payload.len].*;
        return &entry;
    }
}

fn fuzzedSize(smith: *Smith) [2]u16 {
    const cols = smith.valueRangeAtMost(u16, 0, max_fuzzed_cols);
    const rows = smith.valueRangeAtMost(u16, 0, max_fuzzed_rows);
    return .{ cols, rows };
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedMetadata(_: void, smith: *Smith) anyerror!void {
    expectMetadataDecoding(smith) catch |err| std.debug.panic("text metadata decoding property failed: {t}", .{err});
}

/// Decodes a fuzzed payload for a fuzzed screen. A rejection must be the
/// error the reference validator names; an accepted view must keep every
/// accessor inside its bytes and rebuild to exactly them.
fn expectMetadataDecoding(smith: *Smith) anyerror!void {
    const size = fuzzedSize(smith);
    var buffer: [payload_capacity]u8 = undefined;
    const payload = buffer[0..smith.slice(&buffer)];

    const view = View.decode(payload, size) catch |err| {
        const rejection: ?MetadataError = err;
        return std.testing.expectEqual(expectedMetadataError(payload, size), rejection);
    };

    try std.testing.expectEqual(null, expectedMetadataError(payload, size));
    try std.testing.expectEqual(payload.ptr, view.encoded.ptr);
    try std.testing.expectEqual(payload.len, view.encoded.len);
    try expectViewAccessors(view, size);
    try expectBuilderRebuilds(view);
}

const status_weights = [_]Smith.Weight{
    .value(limits.Status, .complete, 3),
    .value(limits.Status, .omitted, 1),
};

const oversized_uri = [_]u8{'u'} ** (limits.max_uri_bytes + 1);

/// Legal flags for a row of `cols` columns: wide padding only on a wrapped
/// row wide enough for the glyph it displaces.
fn generatedRow(smith: *Smith, cols: u16) RowFlags {
    var flags: RowFlags = .{
        .wrap = smith.value(bool),
        .continuation = smith.value(bool),
        .hyperlinks = smith.value(bool),
    };
    flags.wide_padding = flags.wrap and cols >= wide_glyph_columns and smith.value(bool);
    return flags;
}

/// Adds up to `max_generated_links` URIs of fuzzed bytes into `uris`, and
/// sometimes one the quotas refuse, which must leave the builder unchanged.
fn addGeneratedLinks(smith: *Smith, builder: *Builder, uris: *[max_generated_links][max_generated_uri_bytes]u8, lengths: *[max_generated_links]u16) !u16 {
    const link_count = smith.valueRangeAtMost(u16, 0, max_generated_links);
    for (0..link_count) |index| {
        if (smith.boolWeighted(7, 1)) {
            const refused: []const u8 = if (smith.value(bool)) "" else &oversized_uri;
            try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addLink(refused));
            try std.testing.expectEqual(@as(u16, @intCast(index)), builder.link_count);
        }

        lengths[index] = smith.valueRangeAtMost(u16, 1, max_generated_uri_bytes);
        smith.bytes(uris[index][0..lengths[index]]);
        try std.testing.expectEqual(@as(u16, @intCast(index)), try builder.addLink(uris[index][0..lengths[index]]));
    }

    return link_count;
}

/// Adds sorted, row-local runs that name known links, walking the screen
/// from its first cell, and records them in `runs`. Returns how many it
/// added.
fn addGeneratedRuns(smith: *Smith, builder: *Builder, size: [2]u16, link_count: u16, runs: *[max_generated_runs]LinkRun) !u16 {
    if (link_count == 0) {
        return 0;
    }

    const cols = size[0];
    const cell_count = @as(u32, cols) * size[1];
    var position: u32 = 0;
    var run_count: u16 = 0;
    const wanted = smith.valueRangeAtMost(u16, 0, max_generated_runs);
    while (run_count < wanted) : (run_count += 1) {
        const start = position + smith.valueRangeAtMost(u32, 0, cols);
        if (start >= cell_count) {
            break;
        }

        const row_end = (start / cols + 1) * cols;
        runs[run_count] = .{
            .start = start,
            .len = smith.valueRangeAtMost(u32, 1, row_end - start),
            .link_index = @intCast(smith.index(link_count)),
        };
        try builder.addRun(runs[run_count]);
        position = start + runs[run_count].len;
    }

    return run_count;
}

fn buildFuzzedMetadata(_: void, smith: *Smith) anyerror!void {
    expectGeneratedMetadata(smith) catch |err| std.debug.panic("generated text metadata property failed: {t}", .{err});
}

/// Builds a legal replacement for a fuzzed screen and decodes it. It must
/// decode to the rows, URIs and runs it was built from, or to the rows
/// alone when omitted; every strict prefix is truncated, one more byte is
/// trailing and another row count is invalid.
fn expectGeneratedMetadata(smith: *Smith) anyerror!void {
    const size: [2]u16 = .{
        smith.valueRangeAtMost(u16, 1, max_fuzzed_cols),
        smith.valueRangeAtMost(u16, 1, max_fuzzed_rows),
    };
    var scratch: [scratch_capacity]u8 = undefined;
    var builder = Builder.init(&scratch, size[1]);
    var rows: [max_fuzzed_rows]RowFlags = undefined;
    for (rows[0..size[1]], 0..) |*flags, y| {
        flags.* = generatedRow(smith, size[0]);
        builder.setRow(@intCast(y), flags.*);
    }

    var uris: [max_generated_links][max_generated_uri_bytes]u8 = undefined;
    var lengths: [max_generated_links]u16 = undefined;
    const link_count = try addGeneratedLinks(smith, &builder, &uris, &lengths);
    var runs: [max_generated_runs]LinkRun = undefined;
    const run_count = try addGeneratedRuns(smith, &builder, size, link_count, &runs);

    const status = smith.valueWeighted(limits.Status, &status_weights);
    const built = builder.finish(status);
    const view = try View.decode(built.encoded, size);
    try std.testing.expectEqual(built.encoded.ptr, view.encoded.ptr);
    try std.testing.expectEqual(built.encoded.len, view.encoded.len);
    try std.testing.expectEqual(status, view.status);
    try std.testing.expectEqualSlices(RowFlags, rows[0..size[1]], view.rows);
    try expectViewAccessors(view, size);
    if (status == .omitted) {
        try std.testing.expectEqual(@as(u16, 0), view.link_count);
        try std.testing.expectEqual(@as(u16, 0), view.run_count);
        try std.testing.expectEqual(@as(usize, 0), view.uri_bytes.len);
    } else {
        try std.testing.expectEqual(link_count, view.link_count);
        for (0..link_count) |index| {
            try std.testing.expectEqualSlices(u8, uris[index][0..lengths[index]], view.link(@intCast(index)).?);
        }

        var view_runs = view.runs();
        for (runs[0..run_count]) |run| {
            try std.testing.expectEqual(run, view_runs.next().?);
        }

        try std.testing.expectEqual(null, view_runs.next());
    }

    const cut = smith.index(view.encoded.len);
    try std.testing.expectError(error.Truncated, View.decode(view.encoded[0..cut], size));

    scratch[view.encoded.len] = smith.value(u8);
    try std.testing.expectError(error.TrailingBytes, View.decode(scratch[0 .. view.encoded.len + 1], size));

    const other_rows = if (size[1] == max_fuzzed_rows) size[1] - 1 else size[1] + 1;
    try std.testing.expectError(error.InvalidTextMetadata, View.decode(view.encoded, .{ size[0], other_rows }));
}

test "every text metadata fuzz seed reaches its decoder outcome" {
    for (metadata_seeds, metadata_corpus) |seed, entry| {
        const size: [2]u16 = .{ seed.cols, seed.rows };
        const outcome: ?MetadataError = if (View.decode(seed.payload, size)) |_| null else |err| err;
        try std.testing.expectEqual(seed.outcome, outcome);
        try std.testing.expectEqual(seed.outcome, expectedMetadataError(seed.payload, size));

        var smith: Smith = .{ .in = entry };
        try std.testing.expectEqual(size, fuzzedSize(&smith));
        var buffer: [payload_capacity]u8 = undefined;
        try std.testing.expectEqualSlices(u8, seed.payload, buffer[0..smith.slice(&buffer)]);
    }
}

test "fuzz text metadata decoding" {
    try std.testing.fuzz({}, decodeFuzzedMetadata, .{
        .corpus = &metadata_corpus,
    });
}

test "fuzz generated text metadata" {
    try std.testing.fuzz({}, buildFuzzedMetadata, .{});
}
