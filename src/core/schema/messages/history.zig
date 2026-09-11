//! Command history: queries, results, imports, deletion, pruning, captured
//! output and aggregate statistics.

const QueryHistory = @import("QueryHistory.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const EncoderType = @import("../Encoder.zig");
const tags = @import("tags.zig");
const id = @import("../id.zig");
const DecoderType = @import("../Decoder.zig");
const std = @import("std");
const HistoryResults = @import("HistoryResults.zig");
const HistoryResultsView = @import("HistoryResultsView.zig");
const ImportHistory = @import("ImportHistory.zig");
const ImportHistoryView = @import("ImportHistoryView.zig");
const DeleteHistory = @import("DeleteHistory.zig");
const PruneHistory = @import("PruneHistory.zig");
const HistoryPruned = @import("HistoryPruned.zig");
const ReadHistoryOutput = @import("ReadHistoryOutput.zig");
const HistoryOutput = @import("HistoryOutput.zig");
const HistoryStatsQuery = @import("HistoryStatsQuery.zig");
const HistoryStats = @import("HistoryStats.zig");
const HistoryStatsView = @import("HistoryStatsView.zig");
const HistoryEntry = @import("../HistoryEntry.zig");

pub const max_import_entries = 64;
pub const max_import_source_bytes = 256;
pub const max_import_command_bytes = 4096;
pub const max_history_output_bytes = 64 * 1024;
pub const max_history_stats_top = 10;

pub const HistoryMatch = enum(u8) {
    fts = 0,
    fuzzy = 1,
};

pub fn encodeQueryHistory(buffer: []u8, message: QueryHistory) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.query, types.max_history_query_bytes, true);
    if (message.limit == 0 or message.limit > types.max_history_results) {
        return error.InvalidHistoryLimit;
    }
    switch (message.scope) {
        .global => if (message.scope_value.len != 0 or message.pane_id != .invalid)
            return error.InvalidHistoryScope,
        .cwd, .workspace => {
            try codec.validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) {
                return error.InvalidHistoryScope;
            }
        },
        .pane => {
            try codec.validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) {
                return error.InvalidHistoryScope;
            }
        },
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.query_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.query);
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {},
        .cwd, .workspace => try encoder.writeSized16(message.scope_value),
        .pane => try encoder.writeInt(u64, id.raw(message.pane_id)),
    }
    try encoder.writeByte(@intFromBool(message.failed_only));
    try encoder.writeByte(@intFromEnum(message.author));
    try encoder.writeByte(@intFromEnum(message.match));
    try encoder.writeByte(@intFromBool(message.distinct));
    try encoder.writeInt(u16, message.limit);
    try encoder.writeInt(u32, message.offset);
    try encoder.writeInt(u64, message.snapshot_id);
    try encoder.writeInt(u64, message.entry_id);
    return encoder.finish();
}

pub fn decodeQueryHistory(decoder: *DecoderType) !QueryHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const query = try decoder.readSized16();
    try codec.validateBytes(query, types.max_history_query_bytes, true);
    const scope = try codec.decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: id.PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try codec.validateBytes(scope_value, types.max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const failed_only = try decoder.readBool();
    const author = std.enums.fromInt(types.HistoryAuthorFilter, try decoder.readByte()) orelse
        return error.InvalidHistoryAuthor;
    const match = std.enums.fromInt(HistoryMatch, try decoder.readByte()) orelse
        return error.InvalidHistoryMatch;
    const distinct = try decoder.readBool();
    const limit = try decoder.readInt(u16);
    if (limit == 0 or limit > types.max_history_results) {
        return error.InvalidHistoryLimit;
    }
    return .{
        .request_id = request_id,
        .query = query,
        .scope = scope,
        .scope_value = scope_value,
        .pane_id = pane_id,
        .failed_only = failed_only,
        .author = author,
        .match = match,
        .distinct = distinct,
        .limit = limit,
        .offset = try decoder.readInt(u32),
        .snapshot_id = try decoder.readInt(u64),
        .entry_id = try decoder.readInt(u64),
    };
}

pub fn encodeHistoryResults(buffer: []u8, message: HistoryResults) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    if (message.entries.len > types.max_history_results) {
        return error.TooManyHistoryResults;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.history_results));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intCast(message.entries.len));
    try encoder.writeInt(u64, message.snapshot_id);
    try encoder.writeByte(@intFromBool(message.has_more));
    for (message.entries) |entry| try encodeHistoryEntry(&encoder, entry);
    return encoder.finish();
}

pub fn decodeHistoryResults(decoder: *DecoderType) !HistoryResultsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_history_results) {
        return error.TooManyHistoryResults;
    }
    const snapshot_id = try decoder.readInt(u64);
    const has_more = try decoder.readBool();
    const entries_start = decoder.index;
    for (0..entry_count) |_| try skipHistoryEntry(decoder);
    return .{
        .request_id = request_id,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
        .snapshot_id = snapshot_id,
        .has_more = has_more,
    };
}

pub fn encodeImportHistory(buffer: []u8, message: ImportHistory) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.source, max_import_source_bytes, false);
    if (message.entries.len == 0 or message.entries.len > max_import_entries) {
        return error.InvalidImportBatch;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.import_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.source);
    try encoder.writeInt(u64, message.base_sequence);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries) |entry| {
        try codec.validateBytes(entry.command, max_import_command_bytes, false);
        try encoder.writeInt(i64, entry.started_at_ms);
        try encoder.writeSized16(entry.command);
    }
    return encoder.finish();
}

pub fn decodeImportHistory(decoder: *DecoderType) !ImportHistoryView {
    const request_id = try id.request(try decoder.readInt(u64));
    const source = try decoder.readSized16();
    try codec.validateBytes(source, max_import_source_bytes, false);
    const base_sequence = try decoder.readInt(u64);
    const entry_count = try decoder.readInt(u16);
    if (entry_count == 0 or entry_count > max_import_entries) {
        return error.InvalidImportBatch;
    }
    const entries_start = decoder.index;
    for (0..entry_count) |_| {
        _ = try decoder.readInt(i64);
        if ((try decoder.readSized16()).len > max_import_command_bytes) {
            return error.InvalidByteString;
        }
    }
    return .{
        .request_id = request_id,
        .source = source,
        .base_sequence = base_sequence,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

pub fn encodeDeleteHistory(buffer: []u8, message: DeleteHistory) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    if (message.id == 0) {
        return error.InvalidHistoryId;
    }
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.delete_history), buffer, message);
}

pub fn encodePruneHistory(buffer: []u8, message: PruneHistory) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.match, types.max_history_query_bytes, true);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.prune_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {
            if (message.scope_value.len != 0 or message.pane_id != .invalid) {
                return error.InvalidHistoryScope;
            }
        },
        .cwd, .workspace => {
            try codec.validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) {
                return error.InvalidHistoryScope;
            }
            try encoder.writeSized16(message.scope_value);
        },
        .pane => {
            try codec.validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) {
                return error.InvalidHistoryScope;
            }
            try encoder.writeInt(u64, id.raw(message.pane_id));
        },
    }
    try encoder.writeInt(i64, message.before_ms);
    try encoder.writeByte(@intFromBool(message.failed_only));
    try encoder.writeSized16(message.match);
    return encoder.finish();
}

pub fn decodePruneHistory(decoder: *DecoderType) !PruneHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const scope = try codec.decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: id.PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try codec.validateBytes(scope_value, types.max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const before_ms = try decoder.readInt(i64);
    const failed_only = try decoder.readBool();
    const match = try decoder.readSized16();
    try codec.validateBytes(match, types.max_history_query_bytes, true);
    return .{
        .request_id = request_id,
        .scope = scope,
        .scope_value = scope_value,
        .pane_id = pane_id,
        .before_ms = before_ms,
        .failed_only = failed_only,
        .match = match,
    };
}

pub fn encodeHistoryPruned(buffer: []u8, message: HistoryPruned) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    return codec.encodeDerived(@intFromEnum(tags.ServerTag.history_pruned), buffer, message);
}

pub fn encodeReadHistoryOutput(buffer: []u8, message: ReadHistoryOutput) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    if (message.id == 0) {
        return error.InvalidHistoryId;
    }
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.read_history_output), buffer, message);
}

pub fn encodeHistoryOutput(buffer: []u8, message: HistoryOutput) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validateBytes(message.content, max_history_output_bytes, true);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.history_output));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, message.id);
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeInt(u64, message.observed_bytes);
    try encoder.writeSized32(message.content);
    return encoder.finish();
}

pub fn decodeHistoryOutput(decoder: *DecoderType) !HistoryOutput {
    const request_id = try id.request(try decoder.readInt(u64));
    const history_id = try decoder.readInt(u64);
    const truncated = try decoder.readBool();
    const observed_bytes = try decoder.readInt(u64);
    const content = try decoder.readSized32();
    if (content.len > max_history_output_bytes) {
        return error.InvalidByteString;
    }
    return .{
        .request_id = request_id,
        .id = history_id,
        .truncated = truncated,
        .observed_bytes = observed_bytes,
        .content = content,
    };
}

pub fn encodeHistoryStatsQuery(buffer: []u8, message: HistoryStatsQuery) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.history_stats));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {
            if (message.scope_value.len != 0 or message.pane_id != .invalid) {
                return error.InvalidHistoryScope;
            }
        },
        .cwd, .workspace => {
            try codec.validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) {
                return error.InvalidHistoryScope;
            }
            try encoder.writeSized16(message.scope_value);
        },
        .pane => {
            try codec.validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) {
                return error.InvalidHistoryScope;
            }
            try encoder.writeInt(u64, id.raw(message.pane_id));
        },
    }
    try encoder.writeInt(i64, message.since_ms);
    return encoder.finish();
}

pub fn decodeHistoryStatsQuery(decoder: *DecoderType) !HistoryStatsQuery {
    const request_id = try id.request(try decoder.readInt(u64));
    const scope = try codec.decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: id.PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try codec.validateBytes(scope_value, types.max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const since_ms = try decoder.readInt(i64);
    return .{
        .request_id = request_id,
        .scope = scope,
        .scope_value = scope_value,
        .pane_id = pane_id,
        .since_ms = since_ms,
    };
}

pub fn encodeHistoryStats(buffer: []u8, message: HistoryStats) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    if (message.top.len > max_history_stats_top) {
        return error.InvalidHistoryStats;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.history_stats_result));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, message.total);
    try encoder.writeInt(u64, message.unique);
    try encoder.writeByte(@intCast(message.top.len));
    for (message.top) |entry| {
        try codec.validateBytes(entry.command, types.max_history_command_bytes, false);
        try encoder.writeInt(u64, entry.count);
        try encoder.writeSized16(entry.command);
    }
    return encoder.finish();
}

pub fn decodeHistoryStats(decoder: *DecoderType) !HistoryStatsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const total = try decoder.readInt(u64);
    const unique = try decoder.readInt(u64);
    const top_count = try decoder.readByte();
    if (top_count > max_history_stats_top) {
        return error.InvalidHistoryStats;
    }
    const top_start = decoder.index;
    for (0..top_count) |_| {
        _ = try decoder.readInt(u64);
        if ((try decoder.readSized16()).len > types.max_history_command_bytes) {
            return error.InvalidByteString;
        }
    }
    return .{
        .request_id = request_id,
        .total = total,
        .unique = unique,
        .top_count = top_count,
        .encoded_top = decoder.consumed(top_start),
    };
}

fn encodeHistoryEntry(encoder: *EncoderType, entry: HistoryEntry) !void {
    if (entry.id == 0) {
        return error.InvalidHistoryId;
    }
    try codec.validatePaneId(entry.pane_id);
    try codec.validateBytes(entry.command, types.max_history_command_bytes, false);
    // Imported foreign history legitimately lacks a cwd and workspace path.
    try codec.validateBytes(entry.cwd, types.max_cwd_bytes, true);
    try codec.validateBytes(entry.workspace_path, types.max_cwd_bytes, true);
    try codec.validateBytes(entry.provider, types.max_history_provider_bytes, true);
    try encoder.writeInt(u64, entry.id);
    try encoder.writeInt(u64, id.raw(entry.pane_id));
    try encoder.writeInt(i64, entry.started_at_ms);
    try encoder.writeInt(i64, entry.duration_ns);
    if (entry.exit_code) |exit_code| {
        try encoder.writeByte(1);
        try encoder.writeInt(i32, exit_code);
    } else {
        try encoder.writeByte(0);
    }
    try encoder.writeByte(@intFromEnum(entry.status));
    try encoder.writeByte(@intFromEnum(entry.author));
    try encoder.writeByte(@intFromEnum(entry.origin));
    try encoder.writeSized16(entry.provider);
    try encoder.writeSized32(entry.command);
    try encoder.writeSized16(entry.cwd);
    try encoder.writeSized16(entry.workspace_path);
    try encoder.writeByte(@intFromBool(entry.command_truncated));
}

pub fn decodeHistoryEntry(decoder: *DecoderType) !HistoryEntry {
    const history_id = try decoder.readInt(u64);
    if (history_id == 0) {
        return error.InvalidHistoryId;
    }
    const pane_id = try id.pane(try decoder.readInt(u64));
    const started_at_ms = try decoder.readInt(i64);
    const duration_ns = try decoder.readInt(i64);
    const exit_code = if (try decoder.readBool())
        try decoder.readInt(i32)
    else
        null;
    const status = try codec.decodeHistoryStatus(try decoder.readByte());
    const author = std.enums.fromInt(types.HistoryAuthor, try decoder.readByte()) orelse
        return error.InvalidHistoryAuthor;
    const origin = std.enums.fromInt(types.HistoryOrigin, try decoder.readByte()) orelse
        return error.InvalidHistoryOrigin;
    const provider = try decoder.readSized16();
    const command = try decoder.readSized32();
    const cwd = try decoder.readSized16();
    const workspace_path = try decoder.readSized16();
    try codec.validateBytes(command, types.max_history_command_bytes, false);
    try codec.validateBytes(cwd, types.max_cwd_bytes, true);
    try codec.validateBytes(workspace_path, types.max_cwd_bytes, true);
    try codec.validateBytes(provider, types.max_history_provider_bytes, true);
    return .{
        .id = history_id,
        .pane_id = pane_id,
        .started_at_ms = started_at_ms,
        .duration_ns = duration_ns,
        .exit_code = exit_code,
        .status = status,
        .author = author,
        .origin = origin,
        .provider = provider,
        .command = command,
        .cwd = cwd,
        .workspace_path = workspace_path,
        .command_truncated = try decoder.readBool(),
    };
}

/// Walks one entry's field boundaries and byte budgets without scanning its
/// content; `HistoryEntryIterator` validates content as the consumer decodes.
fn skipHistoryEntry(decoder: *DecoderType) !void {
    _ = try decoder.readInt(u64); // id
    _ = try decoder.readInt(u64); // pane_id
    _ = try decoder.readInt(i64); // started_at_ms
    _ = try decoder.readInt(i64); // duration_ns
    if (try decoder.readBool()) {
        _ = try decoder.readInt(i32);
    }
    _ = try decoder.readByte(); // status
    _ = try decoder.readByte(); // author
    _ = try decoder.readByte(); // origin
    if ((try decoder.readSized16()).len > types.max_history_provider_bytes) {
        return error.InvalidByteString;
    }
    if ((try decoder.readSized32()).len > types.max_history_command_bytes) {
        return error.InvalidByteString;
    }
    if ((try decoder.readSized16()).len > types.max_cwd_bytes) {
        return error.InvalidByteString;
    }
    if ((try decoder.readSized16()).len > types.max_cwd_bytes) {
        return error.InvalidByteString;
    }
    _ = try decoder.readBool();
}

test "history page and exact-entry requests preserve their fields" {
    var buffer: [128]u8 = undefined;
    const request: QueryHistory = .{ .request_id = @enumFromInt(7), .offset = 200, .snapshot_id = 900, .entry_id = 42, .limit = 1 };
    const encoded = try encodeQueryHistory(&buffer, request);
    var decoder = DecoderType.init(encoded[1..]);
    const decoded = try decodeQueryHistory(&decoder);
    try std.testing.expectEqual(request.offset, decoded.offset);
    try std.testing.expectEqual(request.snapshot_id, decoded.snapshot_id);
    try std.testing.expectEqual(request.entry_id, decoded.entry_id);
    const reply = try encodeHistoryResults(&buffer, .{ .request_id = request.request_id, .entries = &.{}, .snapshot_id = 900, .has_more = true });
    decoder = DecoderType.init(reply[1..]);
    const result = try decodeHistoryResults(&decoder);
    try std.testing.expectEqual(@as(u64, 900), result.snapshot_id);
    try std.testing.expect(result.has_more);
}
