//! Bounded runtime-to-client delivery policy and logical send transaction.

const core_module = @import("telar-core");
const ReviewResult = @import("../../change_review/Result.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const PathQuery = @import("../../paths/PathQuery.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const Prepared = @import("../attachment/Prepared.zig");
const Transaction = @import("Transaction.zig");
const Completion = @import("Completion.zig");
const std = @import("std");
const Delivery = @import("Delivery.zig");
const Attachments = @import("../attachment/Attachments.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Agents = @import("../../agent/Agents.zig");
const hostmetrics = @import("hostmetrics");
const Sampler = hostmetrics.Sampler;
const Sources = @import("Sources.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const ForegroundProjection = @import("ForegroundProjection.zig");
const Pane = @import("../../pane/Pane.zig");

pub const Effect = union(enum) {
    stopping,
    response: struct {
        offset: u8,
        history_result: ?*QueryResult,
        history_output: ?*OutputResult,
        history_stats: ?*StatsResult,
        change_review: ?*ReviewResult = null,
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

/// The one client every delivery test prepares for.
const test_client = 0;

test "review response remains reserved across a prepared send until commit or client cleanup" {
    for ([_]bool{ false, true }) |abort| {
        var delivery = try Delivery.init(std.testing.allocator);
        defer delivery.deinit(std.testing.allocator);
        var attachments: Attachments = .{};
        defer attachments.deinit(std.testing.allocator);
        var metrics: RuntimeMetrics = .{ .started_ns = 0 };
        const result = try ReviewResult.init(std.testing.allocator);
        try delivery.enqueue(.{ .change_review = result });
        try std.testing.expect(delivery.responses.hasChangeReview());

        const prepared = delivery.stage("review", .{ .response = .{
            .offset = 0,
            .history_result = null,
            .history_output = null,
            .history_stats = null,
            .change_review = result,
        } });
        try std.testing.expect(delivery.responses.hasChangeReview());
        if (abort) {
            delivery.abort(prepared);
            try std.testing.expect(delivery.responses.hasChangeReview());
            delivery.close();
        } else {
            delivery.commit(.{ .prepared = prepared, .attachments = &attachments, .client = test_client, .metrics = &metrics });
            _ = delivery.complete({});
        }

        try std.testing.expect(!delivery.responses.hasChangeReview());
    }
}

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
    var workspace: [core_module.max_agent_workspace_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("telar", copyDisplayPrefix(&workspace, "telar"));
    try std.testing.expectEqual(@as(usize, 0), copyDisplayPrefix(&workspace, "bad\nname").len);
    const long_workspace = "abcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvé-more";
    const shortened_workspace = copyDisplayPrefix(&workspace, long_workspace);
    try std.testing.expect(shortened_workspace.len <= workspace.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_workspace));
    try std.testing.expect(std.mem.endsWith(u8, shortened_workspace, "…"));

    var cwd: [core_module.max_agent_cwd_label_bytes]u8 = undefined;
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
    const pane_id = try core_module.pane(7);
    try std.testing.expect(delivery.setClipboard(pane_id, "pending"));
    var oversized: [core_module.max_clipboard_bytes + 1]u8 = undefined;

    try std.testing.expect(!delivery.setClipboard(try core_module.pane(8), &oversized));

    try std.testing.expect(delivery.clipboard_pending);
    try std.testing.expectEqual(pane_id, delivery.clipboard_pane);
    try std.testing.expectEqualStrings("pending", delivery.clipboard_storage[0..delivery.clipboard_len]);
}

test "clipboard accepts exactly the wire byte limit" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var bytes: [core_module.max_clipboard_bytes]u8 = undefined;
    @memset(&bytes, 'x');

    try std.testing.expect(delivery.setClipboard(try core_module.pane(7), &bytes));

    try std.testing.expectEqual(@as(u32, core_module.max_clipboard_bytes), delivery.clipboard_len);
    try std.testing.expectEqualSlices(u8, &bytes, &delivery.clipboard_storage);
}

test "delivery commits one logical send transaction before completion" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var attachments: Attachments = .{};
    defer attachments.deinit(std.testing.allocator);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };

    delivery.requestStop();
    const prepared = delivery.stage("stopping", .stopping);
    try std.testing.expect(delivery.stopping());
    delivery.commit(.{ .prepared = prepared, .attachments = &attachments, .client = test_client, .metrics = &metrics });
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
    var attachments: Attachments = .{};
    defer attachments.deinit(std.testing.allocator);
    var panes: PaneStore = .{};
    var workspaces: Workspaces = .{};
    var agents: Agents = .{};
    var system_metrics: Sampler = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    const workspace: core_module.WorkspaceLocation = .{
        .workspace = try core_module.workspace(7),
    };
    try delivery.enqueue(.{ .request_failed = .{
        .request_id = @enumFromInt(3),
        .code = .invalid_request,
        .message = "expected",
    } });
    delivery.requestWorkspaceResync(workspace, null);
    const sources: Sources = .{
        .panes = &panes,
        .workspaces = &workspaces,
        .agents = &agents,
        .system_metrics = &system_metrics,
        .proxy_active = false,
        .home = null,
    };

    const first = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &attachments,
        .client = test_client,
        .sources = sources,
        .metrics = &metrics,
    })).?;
    try std.testing.expect((try core_module.decodeServer(first.payload)) == .request_failed);
    delivery.commit(.{ .prepared = first, .attachments = &attachments, .client = test_client, .metrics = &metrics });
    _ = delivery.complete({});

    const second = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &attachments,
        .client = test_client,
        .sources = sources,
        .metrics = &metrics,
    })).?;
    try std.testing.expect((try core_module.decodeServer(second.payload)) == .resync_required);
}

const AttachmentWork = struct {
    index: usize,
    prepared: Prepared,
};
