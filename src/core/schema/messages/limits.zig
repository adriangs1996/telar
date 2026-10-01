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
const limit_reached = @import("../../limit_reached.zig");
const ReportLimit = @import("ReportLimit.zig");
const QueryLimits = @import("QueryLimits.zig");
const LimitList = @import("LimitList.zig");
const LimitListEntry = @import("LimitListEntry.zig");
const LimitListView = @import("LimitListView.zig");

/// Rows one list carries: both of the runtime's tables.
const max_list_entries = 2 * LimitReaches.capacity;

/// Bytes of the largest `report_limit`: the tag, the name, noun and route
/// with their 16-bit lengths, the value, the optional amount and the hits.
pub const max_report_limit_bytes = 1 + 3 * 2 + Limit.max_name_bytes + Limit.max_noun_bytes + LimitReach.max_route_bytes + 8 + 1 + 8 + 4;

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

/// Encodes both of the runtime's tables as the reply to one query. A row
/// whose name is not an identifier stays out rather than failing the reply.
///
/// ```zig
/// const bytes = try limits.encodeLimitList(buffer, .{
///     .request_id = request_id,
///     .runtime = &model.limit_reaches,
///     .clients = &model.client_limit_reaches,
///     .refused_reports = model.refused_limit_reports,
/// });
/// ```
pub fn encodeLimitList(buffer: []u8, list: LimitList) ![]const u8 {
    try codec.validateRequestId(list.request_id);

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.limit_list));
    try encoder.writeInt(u64, id.raw(list.request_id));
    try encoder.writeInt(u64, list.runtime.evicted);
    try encoder.writeInt(u64, list.clients.evicted);
    try encoder.writeInt(u64, list.refused_reports);
    try encoder.writeInt(u16, validRows(list.runtime) + validRows(list.clients));
    try encodeRows(&encoder, list.runtime, .runtime);
    try encodeRows(&encoder, list.clients, .client);
    return encoder.finish();
}

/// Decodes a registry, checking every row once. Example: `const view = try limits.decodeLimitList(decoder);`
pub fn decodeLimitList(decoder: *Decoder) !LimitListView {
    const request_id = try id.request(try decoder.readInt(u64));
    const runtime_evicted = try decoder.readInt(u64);
    const client_evicted = try decoder.readInt(u64);
    const refused_reports = try decoder.readInt(u64);
    const entry_count = try decoder.readInt(u16);
    if (entry_count > max_list_entries) {
        return error.TooManyLimits;
    }

    const start = decoder.index;
    for (0..entry_count) |_| {
        _ = try decodeLimitListEntry(decoder);
    }

    return .{
        .request_id = request_id,
        .runtime_evicted = runtime_evicted,
        .client_evicted = client_evicted,
        .refused_reports = refused_reports,
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

fn validRows(reaches: *const LimitReaches) u16 {
    var valid: u16 = 0;
    for (0..reaches.count) |slot| {
        if (reaches.reachAt(slot).validate()) |_| {
            valid += 1;
        } else |_| {}
    }

    return valid;
}

fn encodeRows(encoder: *Encoder, reaches: *const LimitReaches, origin: LimitOrigin) !void {
    for (0..reaches.count) |slot| {
        const reach = reaches.reachAt(slot);
        reach.validate() catch continue;

        try encodeReach(encoder, reach);
        try encoder.writeByte(@intFromEnum(origin));
        try encoder.writeInt(u64, reaches.hits[slot]);
        try encoder.writeInt(i64, reaches.last_ms[slot]);
    }
}

fn encodeReach(encoder: *Encoder, reach: LimitReach) !void {
    try reach.validate();
    try encoder.writeSized16(reach.limit.name);
    try encoder.writeSized16(reach.limit.noun);
    try encoder.writeInt(u64, reach.limit.value);
    try encoder.writeByte(@intFromBool(reach.requested != null));
    if (reach.requested) |requested| {
        try encoder.writeInt(u64, requested);
    }

    try encoder.writeSized16(reach.route);
}

fn decodeReach(decoder: *Decoder) !LimitReach {
    const limit: Limit = .{
        .name = try decoder.readSized16(),
        .noun = try decoder.readSized16(),
        .value = try decoder.readInt(u64),
    };
    const requested = if (try decoder.readBool()) try decoder.readInt(u64) else null;
    const reach: LimitReach = .{
        .limit = limit,
        .requested = requested,
        .route = try decoder.readSized16(),
    };
    try reach.validate();

    return reach;
}

test "a registry round-trips through its list with both origins" {
    var runtime: LimitReaches = .{};
    var clients: LimitReaches = .{};
    _ = limit_reached.record(
        &clients,
        .{
            .limit = Limit.declare("bars.max_bar_actions", "click actions", 4),
            .requested = 17,
        },
        .{
            .awake_ms = 5_000,
            .real_ms = 5_000,
        },
        3,
    );
    _ = limit_reached.record(
        &runtime,
        limit_reached.unnamed(error.BufferTooSmall, "agent_tick"),
        .{
            .awake_ms = 6_000,
            .real_ms = 6_000,
        },
        1,
    );
    runtime.evicted = 2;

    var buffer: [512]u8 = undefined;
    const bytes = try encodeLimitList(&buffer, .{
        .request_id = @enumFromInt(9),
        .runtime = &runtime,
        .clients = &clients,
        .refused_reports = 4,
    });
    var decoder = Decoder.init(bytes[1..]);
    const view = try decodeLimitList(&decoder);
    try std.testing.expectEqual(@as(u16, 2), view.entry_count);
    try std.testing.expectEqual(@as(u64, 2), view.runtime_evicted);
    try std.testing.expectEqual(@as(u64, 4), view.refused_reports);

    var entries = view.entries();
    const runtime_entry = (try entries.next()).?;
    try std.testing.expectEqual(LimitOrigin.runtime, runtime_entry.origin);
    try std.testing.expectEqualStrings("agent_tick", runtime_entry.reach.route);
    try std.testing.expectEqual(@as(?u64, null), runtime_entry.reach.requested);

    const client_entry = (try entries.next()).?;
    try std.testing.expectEqualStrings("bars.max_bar_actions", client_entry.reach.limit.name);
    try std.testing.expectEqual(@as(?u64, 17), client_entry.reach.requested);
    try std.testing.expectEqual(LimitOrigin.client, client_entry.origin);
    try std.testing.expectEqual(@as(u64, 3), client_entry.hits);
    try std.testing.expectEqual(@as(?LimitListEntry, null), try entries.next());
}

test "a report refuses empty hits, names that are not identifiers and odd routes" {
    var buffer: [256]u8 = undefined;
    const reach: LimitReach = .{
        .limit = Limit.declare("gui.widgets.registry_capacity", "", 256),
    };

    try std.testing.expectError(error.InvalidLimitReport, encodeReportLimit(&buffer, .{
        .reach = reach,
        .hits = 0,
    }));

    var hostile = reach;
    hostile.limit.name = "bad\x1bname";
    try std.testing.expectError(error.InvalidLimitName, encodeReportLimit(&buffer, .{
        .reach = hostile,
        .hits = 1,
    }));

    var routed = reach;
    routed.route = "window draw";
    try std.testing.expectError(error.InvalidLimitRoute, encodeReportLimit(&buffer, .{
        .reach = routed,
        .hits = 1,
    }));

    const bytes = try encodeReportLimit(&buffer, .{
        .reach = reach,
        .hits = 2,
    });
    var decoder = Decoder.init(bytes[1..]);
    const decoded = try decodeReportLimit(&decoder);
    try std.testing.expectEqualStrings("gui.widgets.registry_capacity", decoded.reach.limit.name);
    try std.testing.expectEqual(@as(u32, 2), decoded.hits);
}

test "the largest report fits max_report_limit_bytes exactly" {
    const name = "n" ** Limit.max_name_bytes;
    const noun = "u" ** Limit.max_noun_bytes;
    const route = "r" ** LimitReach.max_route_bytes;
    var buffer: [max_report_limit_bytes]u8 = undefined;
    const bytes = try encodeReportLimit(&buffer, .{
        .reach = .{
            .limit = .{
                .name = name,
                .noun = noun,
                .value = std.math.maxInt(u64),
            },
            .requested = std.math.maxInt(u64),
            .route = route,
        },
        .hits = std.math.maxInt(u32),
    });
    try std.testing.expectEqual(@as(usize, max_report_limit_bytes), bytes.len);
}
