//! Wire bodies of the limit registry: a client's report of the limits it
//! reached, and the query and list that show the runtime's registry.
const bytecodec = @import("bytecodec");
const std = @import("std");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const GenericDerived = @import("../GenericDerived.zig").Type;
const Limit = @import("../../Limit.zig");
const LimitReach = @import("../../LimitReach.zig");
const LimitReaches = @import("../../LimitReaches.zig");
const LimitOrigin = @import("../../LimitOrigin.zig").LimitOrigin;
const ReportLimit = @import("ReportLimit.zig");
const QueryLimits = @import("QueryLimits.zig");
const LimitListEntry = @import("LimitListEntry.zig");
const LimitListView = @import("LimitListView.zig");

/// Encodes one client report. Example: `const bytes = try limits.encodeReportLimit(buffer, report);`
pub fn encodeReportLimit(buffer: []u8, report: ReportLimit) ![]const u8 {
    if (report.hits == 0) {
        return error.InvalidLimitReport;
    }

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.report_limit));
    try encodeReach(&encoder, report.reach);
    try encoder.writeInt(u32, report.hits);
    return encoder.finish();
}

/// Decodes a report borrowing the frame's bytes. Example: `const report = try limits.decodeReportLimit(decoder);`
pub fn decodeReportLimit(decoder: *Decoder) !ReportLimit {
    const reach = try decodeReach(decoder);
    const hits = try decoder.readInt(u32);
    if (hits == 0) {
        return error.InvalidLimitReport;
    }

    return .{
        .reach = reach,
        .hits = hits,
    };
}

/// Encodes the registry query. Example: `const bytes = try limits.encodeQueryLimits(buffer, query);`
pub fn encodeQueryLimits(buffer: []u8, query: QueryLimits) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.query_limits), buffer, query);
}

/// Decodes the registry query. Example: `const query = try limits.decodeQueryLimits(decoder);`
pub fn decodeQueryLimits(decoder: *Decoder) !QueryLimits {
    return GenericDerived(QueryLimits).decode(decoder);
}

/// Encodes every row of a registry as the reply to one query.
/// Example: `const bytes = try limits.encodeLimitList(buffer, request_id, &model.limit_reaches);`
pub fn encodeLimitList(buffer: []u8, request_id: id.RequestId, reaches: *const LimitReaches) ![]const u8 {
    try codec.validateRequestId(request_id);

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.limit_list));
    try encoder.writeInt(u64, id.raw(request_id));
    // A row whose name is not an identifier stays out of the list rather
    // than failing the whole reply.
    var valid: u8 = 0;
    for (0..reaches.count) |slot| {
        if (reaches.reachAt(slot).limit.validate()) |_| {
            valid += 1;
        } else |_| {}
    }

    try encoder.writeByte(valid);
    for (0..reaches.count) |slot| {
        const reach = reaches.reachAt(slot);
        reach.limit.validate() catch continue;

        try encodeReach(&encoder, reach);
        try encoder.writeByte(@intFromEnum(reaches.origin[slot]));
        try encoder.writeInt(u64, reaches.hits[slot]);
        try encoder.writeInt(i64, reaches.last_ms[slot]);
    }

    return encoder.finish();
}

/// Decodes a registry, checking every row once. Example: `const view = try limits.decodeLimitList(decoder);`
pub fn decodeLimitList(decoder: *Decoder) !LimitListView {
    const request_id = try id.request(try decoder.readInt(u64));
    const entry_count = try decoder.readByte();
    if (entry_count > LimitReaches.capacity) {
        return error.TooManyLimits;
    }

    const start = decoder.index;
    for (0..entry_count) |_| {
        _ = try decodeLimitListEntry(decoder);
    }

    return .{
        .request_id = request_id,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(start),
    };
}

pub fn decodeLimitListEntry(decoder: *Decoder) !LimitListEntry {
    const reach = try decodeReach(decoder);
    const origin = std.enums.fromInt(LimitOrigin, try decoder.readByte()) orelse return error.InvalidLimitOrigin;

    return .{
        .reach = reach,
        .origin = origin,
        .hits = try decoder.readInt(u64),
        .last_ms = try decoder.readInt(i64),
    };
}

fn encodeReach(encoder: *Encoder, reach: LimitReach) !void {
    try reach.limit.validate();
    try encoder.writeSized16(reach.limit.name);
    try encoder.writeSized16(reach.limit.noun);
    try encoder.writeInt(u64, reach.limit.value);
    try encoder.writeByte(@intFromBool(reach.requested != null));
    if (reach.requested) |requested| {
        try encoder.writeInt(u64, requested);
    }
}

fn decodeReach(decoder: *Decoder) !LimitReach {
    const limit: Limit = .{
        .name = try decoder.readSized16(),
        .noun = try decoder.readSized16(),
        .value = try decoder.readInt(u64),
    };
    try limit.validate();

    return .{
        .limit = limit,
        .requested = if (try decoder.readBool()) try decoder.readInt(u64) else null,
    };
}

test "a registry round-trips through its list" {
    var reaches: LimitReaches = .{};
    _ = reaches.record(
        .{
            .limit = .{
                .name = "bars.max_bar_actions",
                .noun = "click actions",
                .value = 4,
            },
            .requested = 17,
        },
        .client,
        5_000,
        3,
    );
    _ = reaches.record(
        .{
            .limit = .{
                .name = "session_checkpoint.snapshot_bytes",
                .noun = "bytes",
                .value = 1024,
            },
        },
        .runtime,
        6_000,
        1,
    );

    var buffer: [512]u8 = undefined;
    const bytes = try encodeLimitList(&buffer, @enumFromInt(9), &reaches);
    var decoder = Decoder.init(bytes[1..]);
    const view = try decodeLimitList(&decoder);
    try std.testing.expectEqual(@as(u8, 2), view.entry_count);

    var entries = view.entries();
    const first = (try entries.next()).?;
    try std.testing.expectEqualStrings("bars.max_bar_actions", first.reach.limit.name);
    try std.testing.expectEqual(@as(?u64, 17), first.reach.requested);
    try std.testing.expectEqual(LimitOrigin.client, first.origin);
    try std.testing.expectEqual(@as(u64, 3), first.hits);

    const second = (try entries.next()).?;
    try std.testing.expectEqual(@as(?u64, null), second.reach.requested);
    try std.testing.expectEqual(@as(i64, 6_000), second.last_ms);
    try std.testing.expectEqual(@as(?LimitListEntry, null), try entries.next());
}

test "a report refuses empty hits and names that are not identifiers" {
    var buffer: [256]u8 = undefined;
    const reach: LimitReach = .{
        .limit = .{
            .name = "gui.widgets.registry_capacity",
            .value = 256,
        },
    };

    try std.testing.expectError(error.InvalidLimitReport, encodeReportLimit(&buffer, .{ .reach = reach, .hits = 0 }));

    var hostile = reach;
    hostile.limit.name = "bad\x1bname";
    try std.testing.expectError(error.InvalidLimitName, encodeReportLimit(&buffer, .{ .reach = hostile, .hits = 1 }));

    const bytes = try encodeReportLimit(&buffer, .{ .reach = reach, .hits = 2 });
    var decoder = Decoder.init(bytes[1..]);
    const decoded = try decodeReportLimit(&decoder);
    try std.testing.expectEqualStrings("gui.widgets.registry_capacity", decoded.reach.limit.name);
    try std.testing.expectEqual(@as(u32, 2), decoded.hits);
}
