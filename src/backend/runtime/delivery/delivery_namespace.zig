//! Bounded runtime-to-client delivery policy and logical send transaction.

const QueryResultType = @import("../../history/QueryResult.zig");
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const AttachmentWork = @import("AttachmentWork.zig");
const Transaction = @import("Transaction.zig");
const Completion = @import("Completion.zig");
const std = @import("std");
const max_agent_workspace_label_bytes_module = @import("telar-core").max_agent_workspace_label_bytes;
const max_agent_cwd_label_bytes_module = @import("telar-core").max_agent_cwd_label_bytes;
const Delivery = @import("Delivery.zig");
const pane_module = @import("telar-core").pane;
const max_clipboard_bytes_module = @import("telar-core").max_clipboard_bytes;
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const StateType = @import("../../workspace/State.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const SamplerType = @import("../observability/Sampler.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const workspace_module = @import("telar-core").workspace;
const Sources = @import("Sources.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const decodeServer_module = @import("telar-core").decodeServer;

pub const Effect = union(enum) {
    stopping,
    response: struct {
        offset: u8,
        history_result: ?*QueryResultType,
        history_output: ?*OutputResultType,
        history_stats: ?*StatsResultType,
    },
    resync,
    clipboard,
    client_layout,
    proxy_status,
    agent_revision: u64,
    system_metrics_revision: u64,
    workspace_list_revision: u64,
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
    if (text.len <= limit) {
        return text;
    }
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
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

test "delivery display labels are bounded and valid" {
    var workspace: [max_agent_workspace_label_bytes_module]u8 = undefined;
    try std.testing.expectEqualStrings("telar", copyDisplayPrefix(&workspace, "telar"));
    try std.testing.expectEqual(@as(usize, 0), copyDisplayPrefix(&workspace, "bad\nname").len);
    const long_workspace = "abcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvé-more";
    const shortened_workspace = copyDisplayPrefix(&workspace, long_workspace);
    try std.testing.expect(shortened_workspace.len <= workspace.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_workspace));
    try std.testing.expect(std.mem.endsWith(u8, shortened_workspace, "…"));

    var cwd: [max_agent_cwd_label_bytes_module]u8 = undefined;
    try std.testing.expectEqualStrings(
        "~/sandbox/telar",
        shortenCwd(&cwd, "/Users/adrian/sandbox/telar", "/Users/adrian"),
    );
    const long_cwd = "/Users/adrian/projects/abcdefghijklmnopqrstuvwx/abcdefghijklmnopqrstuvwx/agents/telar";
    const shortened_cwd = shortenCwd(&cwd, long_cwd, "/Users/adrian");
    try std.testing.expect(shortened_cwd.len <= cwd.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_cwd));
    try std.testing.expect(std.mem.startsWith(u8, shortened_cwd, "…"));
    try std.testing.expect(std.mem.endsWith(u8, shortened_cwd, "/agents/telar"));
}

test "oversized clipboard input preserves the pending message" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    const pane_id = try pane_module(7);
    try std.testing.expect(delivery.setClipboard(pane_id, "pending"));
    var oversized: [max_clipboard_bytes_module + 1]u8 = undefined;

    try std.testing.expect(!delivery.setClipboard(try pane_module(8), &oversized));

    try std.testing.expect(delivery.clipboard_pending);
    try std.testing.expectEqual(pane_id, delivery.clipboard_pane);
    try std.testing.expectEqualStrings("pending", delivery.clipboard_storage[0..delivery.clipboard_len]);
}

test "clipboard accepts exactly the wire byte limit" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var bytes: [max_clipboard_bytes_module]u8 = undefined;
    @memset(&bytes, 'x');

    try std.testing.expect(delivery.setClipboard(try pane_module(7), &bytes));

    try std.testing.expectEqual(@as(u32, max_clipboard_bytes_module), delivery.clipboard_len);
    try std.testing.expectEqualSlices(u8, &bytes, &delivery.clipboard_storage);
}

test "delivery commits one logical send transaction before completion" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var attachments: AttachmentStore = .{};
    defer attachments.deinit();
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };

    delivery.requestStop();
    const prepared = delivery.stage("stopping", .stopping);
    try std.testing.expect(delivery.stopping());
    delivery.commit(.{ .prepared = prepared, .attachments = &attachments, .metrics = &metrics });
    try std.testing.expect(delivery.stopping());
    const completion = delivery.complete({});
    try std.testing.expect(completion.stopping_delivered);
    try std.testing.expect(!completion.close_client);
    try std.testing.expect(!delivery.stopping());
}

test "delivery abort closes a prepared transaction" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    const prepared = delivery.stage("payload", .clipboard);
    delivery.abort(prepared);
    try std.testing.expect(std.meta.activeTag(delivery.phase) == .closed);
}

test "delivery preserves management before resync wire order" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var attachments: AttachmentStore = .{};
    defer attachments.deinit();
    var panes: PaneStore = .{};
    var workspaces: StateType = .{};
    var agents: TrackerType = .{};
    var system_metrics: SamplerType = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    const workspace: WorkspaceLocationType = .{
        .workspace = try workspace_module(7),
    };
    try delivery.enqueue(.{ .request_failed = .{
        .request_id = @enumFromInt(3),
        .code = .invalid_request,
        .message = "expected",
    } });
    delivery.requestWorkspaceResync(workspace, null);
    const sources: Sources = .{
        .panes = &panes,
        .workspaces = ReaderType.init(&workspaces),
        .agents = &agents,
        .system_metrics = &system_metrics,
        .proxy_active = false,
        .home = null,
    };

    const first = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &attachments,
        .sources = sources,
        .metrics = &metrics,
    })).?;
    try std.testing.expect((try decodeServer_module(first.payload)) == .request_failed);
    delivery.commit(.{ .prepared = first, .attachments = &attachments, .metrics = &metrics });
    _ = delivery.complete({});

    const second = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &attachments,
        .sources = sources,
        .metrics = &metrics,
    })).?;
    try std.testing.expect((try decodeServer_module(second.payload)) == .resync_required);
}
