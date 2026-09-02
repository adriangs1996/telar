//! Command history: queries, results, imports, deletion, pruning, captured
//! output and aggregate statistics.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const HistoryScope = types.HistoryScope;
const HistoryEntry = types.HistoryEntry;
const HistoryAuthor = types.HistoryAuthor;
const HistoryAuthorFilter = types.HistoryAuthorFilter;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateBytes = codec.validateBytes;
const decodeHistoryScope = codec.decodeHistoryScope;
const decodeHistoryStatus = codec.decodeHistoryStatus;

pub const max_import_entries = 64;
pub const max_import_source_bytes = 256;
pub const max_import_command_bytes = 4096;
pub const max_history_output_bytes = 64 * 1024;
pub const max_history_stats_top = 10;

pub const HistoryMatch = enum(u8) {
    fts = 0,
    fuzzy = 1,
};

pub const QueryHistory = struct {
    request_id: RequestId,
    query: []const u8 = "",
    scope: HistoryScope = .global,
    scope_value: []const u8 = "",
    pane_id: PaneId = .invalid,
    failed_only: bool = false,
    author: HistoryAuthorFilter = .all,
    match: HistoryMatch = .fts,
    distinct: bool = false,
    limit: u16 = 20,
};

pub const HistoryResults = struct {
    request_id: RequestId,
    entries: []const HistoryEntry,
};

pub const HistoryResultsView = struct {
    request_id: RequestId,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(results: HistoryResultsView) HistoryEntryIterator {
        return .{
            .decoder = .init(results.encoded_entries),
            .remaining = results.entry_count,
        };
    }
};

pub const HistoryEntryIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *HistoryEntryIterator) !?HistoryEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return try decodeHistoryEntry(&iterator.decoder);
    }
};

/// One bounded batch of foreign shell history. `source` is the stable
/// identity of the imported file (e.g. `zsh:/home/u/.zsh_history`); the
/// runtime derives one deterministic session from it so re-imports are
/// idempotent, and `base_sequence` orders batches within that session.
pub const ImportHistory = struct {
    request_id: RequestId,
    source: []const u8,
    base_sequence: u64,
    entries: []const ImportEntry,
};

pub const ImportEntry = struct {
    started_at_ms: i64,
    command: []const u8,
};

pub const ImportHistoryView = struct {
    request_id: RequestId,
    source: []const u8,
    base_sequence: u64,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(view: ImportHistoryView) ImportEntryIterator {
        return .{
            .decoder = .init(view.encoded_entries),
            .remaining = view.entry_count,
        };
    }
};

pub const ImportEntryIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *ImportEntryIterator) !?ImportEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        const started_at_ms = try iterator.decoder.readInt(i64);
        const command = try iterator.decoder.readSized16();
        if (command.len == 0 or command.len > max_import_command_bytes)
            return error.InvalidByteString;
        return .{ .started_at_ms = started_at_ms, .command = command };
    }
};

/// Deletes one exact history entry.
pub const DeleteHistory = struct {
    request_id: RequestId,
    id: u64,
};

/// Deletes every history entry matching the bounded filters. `before_ms = 0`
/// means no time bound and an empty `match` means no text filter.
pub const PruneHistory = struct {
    request_id: RequestId,
    scope: HistoryScope = .global,
    scope_value: []const u8 = "",
    pane_id: PaneId = .invalid,
    before_ms: i64 = 0,
    failed_only: bool = false,
    match: []const u8 = "",
};

/// How many entries a delete or prune removed.
pub const HistoryPruned = struct {
    request_id: RequestId,
    removed: u64,
};

/// Reads the captured output of one exact history entry.
pub const ReadHistoryOutput = struct {
    request_id: RequestId,
    id: u64,
};

/// The bounded raw output tail stored for one history entry; empty when
/// capture was off or the command printed nothing.
pub const HistoryOutput = struct {
    request_id: RequestId,
    id: u64,
    truncated: bool,
    observed_bytes: u64,
    content: []const u8,
};

/// Aggregates command history in one scope since a timestamp (0 = all).
pub const HistoryStatsQuery = struct {
    request_id: RequestId,
    scope: HistoryScope = .global,
    scope_value: []const u8 = "",
    pane_id: PaneId = .invalid,
    since_ms: i64 = 0,
};

pub const HistoryStatsTop = struct {
    count: u64,
    command: []const u8,
};

pub const HistoryStats = struct {
    request_id: RequestId,
    total: u64,
    unique: u64,
    top: []const HistoryStatsTop,
};

pub const HistoryStatsView = struct {
    request_id: RequestId,
    total: u64,
    unique: u64,
    top_count: u8,
    encoded_top: []const u8,

    pub fn top(view: HistoryStatsView) HistoryStatsTopIterator {
        return .{ .decoder = .init(view.encoded_top), .remaining = view.top_count };
    }
};

pub const HistoryStatsTopIterator = struct {
    decoder: wire.Decoder,
    remaining: u8,

    pub fn next(iterator: *HistoryStatsTopIterator) !?HistoryStatsTop {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        const count = try iterator.decoder.readInt(u64);
        const command = try iterator.decoder.readSized16();
        if (command.len == 0 or command.len > types.max_history_command_bytes)
            return error.InvalidByteString;
        return .{ .count = count, .command = command };
    }
};

pub fn encodeQueryHistory(buffer: []u8, message: QueryHistory) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.query, types.max_history_query_bytes, true);
    if (message.limit == 0 or message.limit > types.max_history_results)
        return error.InvalidHistoryLimit;
    switch (message.scope) {
        .global => if (message.scope_value.len != 0 or message.pane_id != .invalid)
            return error.InvalidHistoryScope,
        .cwd, .workspace => {
            try validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) return error.InvalidHistoryScope;
        },
        .pane => {
            try validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) return error.InvalidHistoryScope;
        },
    }
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.query_history));
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
    return encoder.finish();
}

pub fn decodeQueryHistory(decoder: *wire.Decoder) !QueryHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const query = try decoder.readSized16();
    try validateBytes(query, types.max_history_query_bytes, true);
    const scope = try decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try validateBytes(scope_value, types.max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const failed_only = try decoder.readBool();
    const author = std.enums.fromInt(HistoryAuthorFilter, try decoder.readByte()) orelse
        return error.InvalidHistoryAuthor;
    const match = std.enums.fromInt(HistoryMatch, try decoder.readByte()) orelse
        return error.InvalidHistoryMatch;
    const distinct = try decoder.readBool();
    const limit = try decoder.readInt(u16);
    if (limit == 0 or limit > types.max_history_results) return error.InvalidHistoryLimit;
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
    };
}

pub fn encodeHistoryResults(buffer: []u8, message: HistoryResults) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.entries.len > types.max_history_results) return error.TooManyHistoryResults;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.history_results));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries) |entry| try encodeHistoryEntry(&encoder, entry);
    return encoder.finish();
}

pub fn decodeHistoryResults(decoder: *wire.Decoder) !HistoryResultsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_history_results) return error.TooManyHistoryResults;
    const entries_start = decoder.index;
    for (0..entry_count) |_| try skipHistoryEntry(decoder);
    return .{
        .request_id = request_id,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

pub fn encodeImportHistory(buffer: []u8, message: ImportHistory) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.source, max_import_source_bytes, false);
    if (message.entries.len == 0 or message.entries.len > max_import_entries)
        return error.InvalidImportBatch;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.import_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.source);
    try encoder.writeInt(u64, message.base_sequence);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries) |entry| {
        try validateBytes(entry.command, max_import_command_bytes, false);
        try encoder.writeInt(i64, entry.started_at_ms);
        try encoder.writeSized16(entry.command);
    }
    return encoder.finish();
}

pub fn decodeImportHistory(decoder: *wire.Decoder) !ImportHistoryView {
    const request_id = try id.request(try decoder.readInt(u64));
    const source = try decoder.readSized16();
    try validateBytes(source, max_import_source_bytes, false);
    const base_sequence = try decoder.readInt(u64);
    const entry_count = try decoder.readInt(u16);
    if (entry_count == 0 or entry_count > max_import_entries)
        return error.InvalidImportBatch;
    const entries_start = decoder.index;
    for (0..entry_count) |_| {
        _ = try decoder.readInt(i64);
        if ((try decoder.readSized16()).len > max_import_command_bytes)
            return error.InvalidByteString;
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
    try validateRequestId(message.request_id);
    if (message.id == 0) return error.InvalidHistoryId;
    return encodeDerived(@intFromEnum(ClientTag.delete_history), DeleteHistory, buffer, message);
}

pub fn encodePruneHistory(buffer: []u8, message: PruneHistory) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.match, types.max_history_query_bytes, true);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.prune_history));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {
            if (message.scope_value.len != 0 or message.pane_id != .invalid)
                return error.InvalidHistoryScope;
        },
        .cwd, .workspace => {
            try validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) return error.InvalidHistoryScope;
            try encoder.writeSized16(message.scope_value);
        },
        .pane => {
            try validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) return error.InvalidHistoryScope;
            try encoder.writeInt(u64, id.raw(message.pane_id));
        },
    }
    try encoder.writeInt(i64, message.before_ms);
    try encoder.writeByte(@intFromBool(message.failed_only));
    try encoder.writeSized16(message.match);
    return encoder.finish();
}

pub fn decodePruneHistory(decoder: *wire.Decoder) !PruneHistory {
    const request_id = try id.request(try decoder.readInt(u64));
    const scope = try decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try validateBytes(scope_value, types.max_cwd_bytes, false);
        },
        .pane => pane_id = try id.pane(try decoder.readInt(u64)),
    }
    const before_ms = try decoder.readInt(i64);
    const failed_only = try decoder.readBool();
    const match = try decoder.readSized16();
    try validateBytes(match, types.max_history_query_bytes, true);
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
    try validateRequestId(message.request_id);
    return encodeDerived(@intFromEnum(ServerTag.history_pruned), HistoryPruned, buffer, message);
}

pub fn encodeReadHistoryOutput(buffer: []u8, message: ReadHistoryOutput) ![]const u8 {
    try validateRequestId(message.request_id);
    if (message.id == 0) return error.InvalidHistoryId;
    return encodeDerived(@intFromEnum(ClientTag.read_history_output), ReadHistoryOutput, buffer, message);
}

pub fn encodeHistoryOutput(buffer: []u8, message: HistoryOutput) ![]const u8 {
    try validateRequestId(message.request_id);
    try validateBytes(message.content, max_history_output_bytes, true);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.history_output));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, message.id);
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeInt(u64, message.observed_bytes);
    try encoder.writeSized32(message.content);
    return encoder.finish();
}

pub fn decodeHistoryOutput(decoder: *wire.Decoder) !HistoryOutput {
    const request_id = try id.request(try decoder.readInt(u64));
    const history_id = try decoder.readInt(u64);
    const truncated = try decoder.readBool();
    const observed_bytes = try decoder.readInt(u64);
    const content = try decoder.readSized32();
    if (content.len > max_history_output_bytes) return error.InvalidByteString;
    return .{
        .request_id = request_id,
        .id = history_id,
        .truncated = truncated,
        .observed_bytes = observed_bytes,
        .content = content,
    };
}

pub fn encodeHistoryStatsQuery(buffer: []u8, message: HistoryStatsQuery) ![]const u8 {
    try validateRequestId(message.request_id);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.history_stats));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.scope));
    switch (message.scope) {
        .global => {
            if (message.scope_value.len != 0 or message.pane_id != .invalid)
                return error.InvalidHistoryScope;
        },
        .cwd, .workspace => {
            try validateBytes(message.scope_value, types.max_cwd_bytes, false);
            if (message.pane_id != .invalid) return error.InvalidHistoryScope;
            try encoder.writeSized16(message.scope_value);
        },
        .pane => {
            try validatePaneId(message.pane_id);
            if (message.scope_value.len != 0) return error.InvalidHistoryScope;
            try encoder.writeInt(u64, id.raw(message.pane_id));
        },
    }
    try encoder.writeInt(i64, message.since_ms);
    return encoder.finish();
}

pub fn decodeHistoryStatsQuery(decoder: *wire.Decoder) !HistoryStatsQuery {
    const request_id = try id.request(try decoder.readInt(u64));
    const scope = try decodeHistoryScope(try decoder.readByte());
    var scope_value: []const u8 = "";
    var pane_id: PaneId = .invalid;
    switch (scope) {
        .global => {},
        .cwd, .workspace => {
            scope_value = try decoder.readSized16();
            try validateBytes(scope_value, types.max_cwd_bytes, false);
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
    try validateRequestId(message.request_id);
    if (message.top.len > max_history_stats_top) return error.InvalidHistoryStats;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.history_stats_result));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, message.total);
    try encoder.writeInt(u64, message.unique);
    try encoder.writeByte(@intCast(message.top.len));
    for (message.top) |entry| {
        try validateBytes(entry.command, types.max_history_command_bytes, false);
        try encoder.writeInt(u64, entry.count);
        try encoder.writeSized16(entry.command);
    }
    return encoder.finish();
}

pub fn decodeHistoryStats(decoder: *wire.Decoder) !HistoryStatsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const total = try decoder.readInt(u64);
    const unique = try decoder.readInt(u64);
    const top_count = try decoder.readByte();
    if (top_count > max_history_stats_top) return error.InvalidHistoryStats;
    const top_start = decoder.index;
    for (0..top_count) |_| {
        _ = try decoder.readInt(u64);
        if ((try decoder.readSized16()).len > types.max_history_command_bytes)
            return error.InvalidByteString;
    }
    return .{
        .request_id = request_id,
        .total = total,
        .unique = unique,
        .top_count = top_count,
        .encoded_top = decoder.consumed(top_start),
    };
}

fn encodeHistoryEntry(encoder: *wire.Encoder, entry: HistoryEntry) !void {
    if (entry.id == 0) return error.InvalidHistoryId;
    try validatePaneId(entry.pane_id);
    try validateBytes(entry.command, types.max_history_command_bytes, false);
    // Imported foreign history legitimately lacks a cwd and workspace path.
    try validateBytes(entry.cwd, types.max_cwd_bytes, true);
    try validateBytes(entry.workspace_path, types.max_cwd_bytes, true);
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
    try encoder.writeSized32(entry.command);
    try encoder.writeSized16(entry.cwd);
    try encoder.writeSized16(entry.workspace_path);
}

fn decodeHistoryEntry(decoder: *wire.Decoder) !HistoryEntry {
    const history_id = try decoder.readInt(u64);
    if (history_id == 0) return error.InvalidHistoryId;
    const pane_id = try id.pane(try decoder.readInt(u64));
    const started_at_ms = try decoder.readInt(i64);
    const duration_ns = try decoder.readInt(i64);
    const exit_code = if (try decoder.readBool())
        try decoder.readInt(i32)
    else
        null;
    const status = try decodeHistoryStatus(try decoder.readByte());
    const author = std.enums.fromInt(HistoryAuthor, try decoder.readByte()) orelse
        return error.InvalidHistoryAuthor;
    const command = try decoder.readSized32();
    const cwd = try decoder.readSized16();
    const workspace_path = try decoder.readSized16();
    try validateBytes(command, types.max_history_command_bytes, false);
    try validateBytes(cwd, types.max_cwd_bytes, true);
    try validateBytes(workspace_path, types.max_cwd_bytes, true);
    return .{
        .id = history_id,
        .pane_id = pane_id,
        .started_at_ms = started_at_ms,
        .duration_ns = duration_ns,
        .exit_code = exit_code,
        .status = status,
        .author = author,
        .command = command,
        .cwd = cwd,
        .workspace_path = workspace_path,
    };
}

/// Walks one entry's field boundaries and byte budgets without scanning its
/// content; `HistoryEntryIterator` validates content as the consumer decodes.
fn skipHistoryEntry(decoder: *wire.Decoder) !void {
    _ = try decoder.readInt(u64); // id
    _ = try decoder.readInt(u64); // pane_id
    _ = try decoder.readInt(i64); // started_at_ms
    _ = try decoder.readInt(i64); // duration_ns
    if (try decoder.readBool()) _ = try decoder.readInt(i32);
    _ = try decoder.readByte(); // status
    _ = try decoder.readByte(); // author
    if ((try decoder.readSized32()).len > types.max_history_command_bytes)
        return error.InvalidByteString;
    if ((try decoder.readSized16()).len > types.max_cwd_bytes) return error.InvalidByteString;
    if ((try decoder.readSized16()).len > types.max_cwd_bytes) return error.InvalidByteString;
}
