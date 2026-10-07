//! Bounded runtime-to-client delivery policy and logical send transaction.

const core_module = @import("telar-core");
const QueryResult = @import("../../history/QueryResult.zig");
const PathQuery = @import("../../paths/PathQuery.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const Prepared = @import("../attachment/Prepared.zig");
const Transaction = @import("Transaction.zig");
const Completion = @import("Completion.zig");
const std = @import("std");
const ForegroundProjection = @import("ForegroundProjection.zig");

pub const Effect = union(enum) {
    stopping,
    response: struct {
        offset: u8,
        history_result: ?*QueryResult,
        history_output: ?*OutputResult,
        history_stats: ?*StatsResult,
        path_results: ?*PathQuery = null,
    },
    resync,
    clipboard,
    client_layout,
    proxy_status,
    agent_revision: u64,
    system_metrics_revision: u64,
    workspace_list_revision: u64,
    foreground: ForegroundProjection,
    attachment: AttachmentWork,
};

pub const Phase = union(enum) {
    ready,
    prepared: Transaction,
    in_flight: Completion,
    closed,
};

/// Cuts `text` to at most `limit` bytes on a UTF-8 boundary.
pub fn truncateUtf8(text: []const u8, limit: usize) []const u8 {
    return core_module.utf8Prefix(text, limit);
}

pub fn copyDisplayPrefix(output: []u8, source: []const u8) []const u8 {
    if (!validDisplayText(source)) {
        return output[0..0];
    }
    if (source.len <= output.len) {
        @memcpy(output[0..source.len], source);
        return output[0..source.len];
    }
    const ellipsis = "…";
    if (output.len < ellipsis.len) {
        return output[0..0];
    }
    var end = output.len - ellipsis.len;
    while (end != 0 and isUtf8Continuation(source[end])) end -= 1;
    @memcpy(output[0..end], source[0..end]);
    @memcpy(output[end..][0..ellipsis.len], ellipsis);
    return output[0 .. end + ellipsis.len];
}

pub fn shortenCwd(output: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    if (!validDisplayText(path)) {
        return output[0..0];
    }
    var prefix: []const u8 = "";
    var suffix = path;
    if (home) |home_path| {
        if (home_path.len != 0 and std.mem.startsWith(u8, path, home_path) and
            (path.len == home_path.len or path[home_path.len] == '/'))
        {
            prefix = "~";
            suffix = path[home_path.len..];
        }
    }
    if (prefix.len + suffix.len <= output.len) {
        @memcpy(output[0..prefix.len], prefix);
        @memcpy(output[prefix.len..][0..suffix.len], suffix);
        return output[0 .. prefix.len + suffix.len];
    }
    const ellipsis = "…";
    if (output.len < ellipsis.len) {
        return output[0..0];
    }
    const available = output.len - ellipsis.len;
    var start = suffix.len -| available;
    while (start < suffix.len and isUtf8Continuation(suffix[start])) start += 1;
    const tail = suffix[start..];
    @memcpy(output[0..ellipsis.len], ellipsis);
    @memcpy(output[ellipsis.len..][0..tail.len], tail);
    return output[0 .. ellipsis.len + tail.len];
}

fn validDisplayText(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        return false;
    }
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

const AttachmentWork = struct {
    index: usize,
    prepared: Prepared,
};
