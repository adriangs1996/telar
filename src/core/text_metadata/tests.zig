const std = @import("std");
const Builder = @import("Builder.zig");
const View = @import("View.zig");
const Storage = @import("Storage.zig");
const limits = @import("limits.zig");
const RowFlags = @import("RowFlags.zig").RowFlags;

const uri = "https://example.test/a";
const fixture_rows = 2;
const links_start = limits.header_size + fixture_rows;
const runs_start = links_start + 2 * limits.link_size;

fn linked(buffer: []u8) !View {
    var builder = Builder.init(buffer, fixture_rows);
    builder.setRow(0, .{ .wrap = true, .hyperlinks = true });
    builder.setRow(1, .{ .continuation = true, .hyperlinks = true });
    const first = try builder.addLink(uri);
    const second = try builder.addLink(uri);
    try builder.addRun(.{ .start = 0, .len = 2, .link_index = first });
    try builder.addRun(.{ .start = 3, .len = 1, .link_index = second });
    try builder.addRun(.{ .start = 4, .len = 4, .link_index = first });
    return builder.finish(.complete);
}

test "text metadata preserves row semantics and distinct identities with identical URIs" {
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    const original = try linked(&scratch);
    const decoded = try View.decode(original.encoded, .{ 4, 2 });
    try std.testing.expectEqual(limits.Status.complete, decoded.status);
    try std.testing.expectEqual(@as(u16, 2), decoded.link_count);
    try std.testing.expectEqual(@as(u16, 3), decoded.run_count);
    try std.testing.expectEqualSlices(RowFlags, &.{ .{ .wrap = true, .hyperlinks = true }, .{ .continuation = true, .hyperlinks = true } }, decoded.rows);
    try std.testing.expectEqualStrings(uri, decoded.link(0).?);
    try std.testing.expectEqualStrings(uri, decoded.link(1).?);
    try std.testing.expect(decoded.link(2) == null);
    try std.testing.expectEqual(@as(u16, 0), decoded.at(0).?.link_index);
    try std.testing.expectEqual(@as(u16, 0), decoded.at(1).?.link_index);
    try std.testing.expect(decoded.at(2) == null);
    try std.testing.expectEqual(@as(u16, 1), decoded.at(3).?.link_index);
    try std.testing.expectEqual(@as(u16, 0), decoded.at(7).?.link_index);
    try std.testing.expect(decoded.at(8) == null);
    var runs = decoded.runs();
    try std.testing.expectEqual(@as(u32, 0), runs.next().?.start);
    try std.testing.expectEqual(@as(u32, 3), runs.next().?.start);
    try std.testing.expectEqual(@as(u32, 4), runs.next().?.start);
    try std.testing.expect(runs.next() == null);
}

test "text metadata rejects truncated and extended replacements" {
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    const original = try linked(&scratch);
    for (0..original.encoded.len) |length| {
        try std.testing.expectError(error.Truncated, View.decode(original.encoded[0..length], .{ 4, 2 }));
    }

    scratch[original.encoded.len] = 0;
    try std.testing.expectError(error.TrailingBytes, View.decode(scratch[0 .. original.encoded.len + 1], .{ 4, 2 }));
    const excessive = try std.testing.allocator.alloc(u8, limits.capacity(fixture_rows) + 1);
    defer std.testing.allocator.free(excessive);
    try std.testing.expectError(error.TextMetadataTooLarge, View.decode(excessive, .{ 4, 2 }));
}

test "text metadata rejects malformed counts status row flags and URI offsets" {
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    const original = try linked(&scratch);
    var corrupted: [limits.capacity(fixture_rows)]u8 = undefined;
    const mutations = .{
        .{ .offset = 0, .bytes = &[_]u8{2} },
        .{ .offset = 0, .bytes = &[_]u8{1} }, // Omitted must not retain links.
        .{ .offset = 1, .bytes = &[_]u8{ 1, 0 } },
        .{ .offset = 3, .bytes = &[_]u8{ 1, 1 } }, // 257 links.
        .{ .offset = 5, .bytes = &[_]u8{ 1, 8 } }, // 2049 runs.
        .{ .offset = 7, .bytes = &[_]u8{ 1, 0, 1, 0 } }, // 65537 URI bytes.
        .{ .offset = limits.header_size, .bytes = &[_]u8{0x10} },
        .{ .offset = limits.header_size, .bytes = &[_]u8{4} }, // Padding without wrap.
        .{ .offset = links_start, .bytes = &[_]u8{ 1, 0, 0, 0 } },
        .{ .offset = links_start + 4, .bytes = &[_]u8{ 0, 0 } },
        .{ .offset = links_start + 4, .bytes = &[_]u8{ 1, 16 } }, // URI over 4096 bytes.
        .{ .offset = links_start + limits.link_size, .bytes = &[_]u8{ 0, 0, 0, 0 } },
        .{ .offset = links_start + limits.link_size + 4, .bytes = &[_]u8{ 1, 0 } }, // Unclaimed URI suffix.
    };
    inline for (mutations) |mutation| {
        @memcpy(corrupted[0..original.encoded.len], original.encoded);
        @memcpy(corrupted[mutation.offset..][0..mutation.bytes.len], mutation.bytes);
        try std.testing.expectError(error.InvalidTextMetadata, View.decode(corrupted[0..original.encoded.len], .{ 4, 2 }));
    }
}

test "text metadata rejects zero overlapping unordered overflowing and cross-row runs" {
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    const original = try linked(&scratch);
    var corrupted: [limits.capacity(fixture_rows)]u8 = undefined;
    const mutations = .{
        .{ .offset = runs_start + 4, .bytes = &[_]u8{ 0, 0, 0, 0 } },
        .{ .offset = runs_start + 4, .bytes = &[_]u8{ 5, 0, 0, 0 } }, // Crosses row 0.
        .{ .offset = runs_start + 4, .bytes = &[_]u8{ 9, 0, 0, 0 } }, // Past the screen.
        .{ .offset = runs_start + 8, .bytes = &[_]u8{ 2, 0 } }, // Unknown URI identity.
        .{ .offset = runs_start + limits.run_size, .bytes = &[_]u8{ 1, 0, 0, 0 } }, // Overlap.
        .{ .offset = runs_start + limits.run_size, .bytes = &[_]u8{ 0, 0, 0, 0 } }, // Reordered.
        .{ .offset = runs_start + limits.run_size, .bytes = &[_]u8{ 255, 255, 255, 255 } },
        .{ .offset = runs_start + limits.run_size + 4, .bytes = &[_]u8{ 255, 255, 255, 255 } },
    };
    inline for (mutations) |mutation| {
        @memcpy(corrupted[0..original.encoded.len], original.encoded);
        @memcpy(corrupted[mutation.offset..][0..mutation.bytes.len], mutation.bytes);
        try std.testing.expectError(error.InvalidTextMetadata, View.decode(corrupted[0..original.encoded.len], .{ 4, 2 }));
    }

    try std.testing.expectError(error.InvalidTextMetadata, View.decode(original.encoded, .{ 0, 2 }));
}

test "text metadata omitted replacements keep wrap semantics and erase all link state" {
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    var builder = Builder.init(&scratch, fixture_rows);
    builder.setRow(0, .{ .wrap = true, .wide_padding = true, .hyperlinks = true });
    builder.setRow(1, .{ .continuation = true });
    const index = try builder.addLink(uri);
    try builder.addRun(.{ .start = 0, .len = 1, .link_index = index });
    const omitted = try View.decode(builder.finish(.omitted).encoded, .{ 4, 2 });
    try std.testing.expectEqual(limits.Status.omitted, omitted.status);
    try std.testing.expectEqual(@as(u16, 0), omitted.link_count);
    try std.testing.expectEqual(@as(u16, 0), omitted.run_count);
    try std.testing.expectEqual(@as(usize, 0), omitted.uri_bytes.len);
    try std.testing.expect(omitted.rows[0].wrap and omitted.rows[0].wide_padding);
    try std.testing.expect(omitted.rows[1].continuation);
    try std.testing.expect(omitted.at(0) == null);
}

test "text metadata enforces each independent URI quota without losing admitted entries" {
    var scratch: [limits.capacity(1)]u8 = undefined;
    var builder = Builder.init(&scratch, 1);
    try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addLink(""));
    const oversized = [_]u8{'x'} ** (limits.max_uri_bytes + 1);
    try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addLink(&oversized));
    try std.testing.expectEqual(@as(u16, 0), builder.link_count);
    for (0..limits.max_links) |_| {
        _ = try builder.addLink("x");
    }

    try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addLink("x"));
    const identities = try View.decode(builder.finish(.complete).encoded, .{ 1, 1 });
    try std.testing.expectEqual(@as(u16, limits.max_links), identities.link_count);
    try std.testing.expectEqualStrings("x", identities.link(limits.max_links - 1).?);

    builder = Builder.init(&scratch, 1);
    const uri_block = [_]u8{'u'} ** limits.max_uri_bytes;
    for (0..limits.max_total_uri_bytes / limits.max_uri_bytes) |_| {
        _ = try builder.addLink(&uri_block);
    }

    try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addLink("x"));
    const full = try View.decode(builder.finish(.complete).encoded, .{ 1, 1 });
    try std.testing.expectEqual(@as(usize, limits.max_total_uri_bytes), full.uri_bytes.len);
    try std.testing.expectEqualStrings(&uri_block, full.link(full.link_count - 1).?);
}

test "text metadata accepts the maximal row run and URI quotas together" {
    const rows = std.math.maxInt(u16);
    const scratch = try std.testing.allocator.alloc(u8, limits.capacity(rows));
    defer std.testing.allocator.free(scratch);
    var builder = Builder.init(scratch, rows);
    const block = [_]u8{'u'} ** (limits.max_total_uri_bytes / limits.max_links);
    for (0..limits.max_links) |_| {
        _ = try builder.addLink(&block);
    }
    for (0..limits.max_runs) |index| {
        try builder.addRun(.{ .start = @intCast(index), .len = 1, .link_index = @intCast(index % limits.max_links) });
    }

    try std.testing.expectError(error.TextMetadataQuotaExceeded, builder.addRun(.{ .start = limits.max_runs, .len = 1, .link_index = 0 }));
    const maximum = try View.decode(builder.finish(.complete).encoded, .{ 1, rows });
    try std.testing.expectEqual(limits.max_encoded_size, maximum.encoded.len);
    try std.testing.expectEqual(@as(u16, limits.max_links), maximum.link_count);
    try std.testing.expectEqual(@as(u16, limits.max_runs), maximum.run_count);
    try std.testing.expectEqual(@as(u16, limits.max_links - 1), maximum.at(limits.max_runs - 1).?.link_index);
}

test "text metadata owned replacement reuses capacity and survives failed geometry reservation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var storage = try Storage.init(allocator, fixture_rows);
    defer storage.deinit(allocator);
    const pointer = storage.buffer.ptr;
    var scratch: [limits.capacity(fixture_rows)]u8 = undefined;
    const original = try linked(&scratch);
    storage.replace(original);
    @memset(&scratch, 0);
    try std.testing.expectEqualStrings(uri, storage.view().link(1).?);
    for (0..1000) |_| {
        var empty = Builder.init(&scratch, fixture_rows);
        storage.replace(empty.finish(.complete));
        try storage.reserve(allocator, fixture_rows);
        storage.replace(try linked(&scratch));
    }

    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expectEqual(pointer, storage.buffer.ptr);
    try std.testing.expectEqualStrings(uri, storage.view().link(0).?);
    try std.testing.expectError(error.OutOfMemory, storage.reserve(allocator, fixture_rows + 1));
    try std.testing.expectEqual(pointer, storage.buffer.ptr);
    try std.testing.expectEqualStrings(uri, storage.view().link(1).?);
}

test {
    _ = @import("frame_tests.zig");
}

test "text metadata owned storage accepts the maximum wire row count" {
    const rows = std.math.maxInt(u16);
    var storage = try Storage.init(std.testing.allocator, rows);
    defer storage.deinit(std.testing.allocator);
    const view = try View.decode(storage.view().encoded, .{ 1, rows });
    try std.testing.expectEqual(@as(usize, rows), view.rows.len);
    try std.testing.expectEqual(@as(usize, limits.header_size) + rows, view.encoded.len);
}

test "text metadata wide padding requires a row wide enough for the displaced glyph" {
    var scratch: [limits.capacity(1)]u8 = undefined;
    var builder = Builder.init(&scratch, 1);
    builder.setRow(0, .{ .wrap = true, .wide_padding = true });
    const view = builder.finish(.complete);
    try std.testing.expectError(error.InvalidTextMetadata, View.decode(view.encoded, .{ 1, 1 }));
    _ = try View.decode(view.encoded, .{ 2, 1 });
}
