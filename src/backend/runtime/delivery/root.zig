//! Bounded runtime-to-client delivery policy and logical send transaction.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const client_layout_store = @import("../application/client_layout_store.zig");
const response_queue = @import("response_queue.zig");
const runtime_encoder = @import("encoder.zig");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const telemetry_mod = @import("../observability/root.zig").telemetry;

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;
pub const AttachmentStore = attachment_mod.AttachmentStore;
pub const PaneStore = pane_mod.PaneStore;
pub const PendingFailure = response_queue.PendingFailure;
pub const PendingSuggestion = response_queue.PendingSuggestion;
pub const PendingTabSnapshot = response_queue.PendingTabSnapshot;
pub const PendingWorkspaceSnapshot = response_queue.PendingWorkspaceSnapshot;
pub const PendingTabCreated = response_queue.PendingTabCreated;
pub const PendingTabRenamed = response_queue.PendingTabRenamed;
pub const PendingNotification = response_queue.PendingNotification;
pub const PendingResponse = response_queue.PendingResponse;
pub const ResponseQueue = response_queue.ResponseQueue;
pub const EncodeContext = runtime_encoder.EncodeContext;
pub const encodeResponse = runtime_encoder.encodeResponse;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Sources = @import("Sources.zig");

pub const Prepared = @import("Prepared.zig");

pub const Preparation = @import("Preparation.zig");

pub const Commit = @import("Commit.zig");

pub const Completion = @import("Completion.zig");

const AttachmentWork = @import("AttachmentWork.zig");

pub const Effect = union(enum) {
    stopping,
    response: struct {
        offset: u8,
        history_result: ?*history.model.QueryResult,
        history_output: ?*history.model.OutputResult,
        history_stats: ?*history.model.StatsResult,
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

const Transaction = @import("Transaction.zig");

pub const Phase = union(enum) {
    ready,
    prepared: Transaction,
    in_flight: Completion,
    closed,
};

pub const Delivery = @import("Delivery.zig");

/// Cuts `text` to at most `limit` bytes on a UTF-8 boundary.
pub fn truncateUtf8(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) {
        return text;
    }
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) : (end -= 1) {}
    return text[0..end];
}

const AgentDisplayStorage = @import("AgentDisplayStorage.zig");

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
    var workspace: [schema.max_agent_workspace_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("telar", copyDisplayPrefix(&workspace, "telar"));
    try std.testing.expectEqual(@as(usize, 0), copyDisplayPrefix(&workspace, "bad\nname").len);
    const long_workspace = "abcdefghijklmnopqrstuvwxabcdefghijklmnopqrstuvé-more";
    const shortened_workspace = copyDisplayPrefix(&workspace, long_workspace);
    try std.testing.expect(shortened_workspace.len <= workspace.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shortened_workspace));
    try std.testing.expect(std.mem.endsWith(u8, shortened_workspace, "…"));

    var cwd: [schema.max_agent_cwd_label_bytes]u8 = undefined;
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
    const pane_id = try schema.id.pane(7);
    try std.testing.expect(delivery.setClipboard(pane_id, "pending"));
    var oversized: [schema.max_clipboard_bytes + 1]u8 = undefined;

    try std.testing.expect(!delivery.setClipboard(try schema.id.pane(8), &oversized));

    try std.testing.expect(delivery.clipboard_pending);
    try std.testing.expectEqual(pane_id, delivery.clipboard_pane);
    try std.testing.expectEqualStrings("pending", delivery.clipboard_storage[0..delivery.clipboard_len]);
}

test "clipboard accepts exactly the wire byte limit" {
    var delivery = try Delivery.init(std.testing.allocator);
    defer delivery.deinit(std.testing.allocator);
    var bytes: [schema.max_clipboard_bytes]u8 = undefined;
    @memset(&bytes, 'x');

    try std.testing.expect(delivery.setClipboard(try schema.id.pane(7), &bytes));

    try std.testing.expectEqual(@as(u32, schema.max_clipboard_bytes), delivery.clipboard_len);
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
    var workspaces: workspace_mod.State = .{};
    var agents: agent_mod.Tracker = .{};
    var system_metrics: system_metrics_mod.Sampler = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    const workspace: schema.WorkspaceLocation = .{
        .workspace = try schema.id.workspace(7),
    };
    try delivery.enqueue(.{ .request_failed = .{
        .request_id = @enumFromInt(3),
        .code = .invalid_request,
        .message = "expected",
    } });
    delivery.requestWorkspaceResync(workspace, null);
    const sources: Sources = .{
        .panes = &panes,
        .workspaces = workspace_mod.Reader.init(&workspaces),
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
    try std.testing.expect((try schema.decodeServer(first.payload)) == .request_failed);
    delivery.commit(.{ .prepared = first, .attachments = &attachments, .metrics = &metrics });
    _ = delivery.complete({});

    const second = (try delivery.prepare(.{
        .io = std.testing.io,
        .attachments = &attachments,
        .sources = sources,
        .metrics = &metrics,
    })).?;
    try std.testing.expect((try schema.decodeServer(second.payload)) == .resync_required);
}
