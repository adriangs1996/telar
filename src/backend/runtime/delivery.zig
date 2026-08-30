//! Bounded runtime-to-client delivery policy and logical send transaction.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../agent/root.zig");
const history = @import("../history/root.zig");
const pane_mod = @import("../pane/root.zig");
const workspace_mod = @import("../workspace/root.zig");
const attachment_mod = @import("attachment.zig");
const response_queue = @import("response_queue.zig");
const runtime_encoder = @import("encoder.zig");
const system_metrics_mod = @import("system_metrics.zig");
const telemetry_mod = @import("telemetry.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;
const ResponseQueue = response_queue.ResponseQueue;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Sources = struct {
    panes: *const PaneStore,
    workspaces: workspace_mod.Reader,
    agents: *const agent_mod.Tracker,
    system_metrics: *const system_metrics_mod.Sampler,
    proxy_active: bool,
    home: ?[]const u8,
};

pub const Prepared = struct {
    payload: []const u8,
    ticket: u64,
};

pub const Preparation = struct {
    io: Io,
    attachments: *AttachmentStore,
    sources: Sources,
    metrics: *RuntimeMetrics,
};

pub const Commit = struct {
    prepared: Prepared,
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
};

pub const Completion = struct {
    detach_pane: ?schema.PaneId = null,
    close_client: bool = false,
    stopping_delivered: bool = false,
};

const AttachmentWork = struct {
    index: usize,
    prepared: attachment_mod.Attachment.Prepared,
};

const Effect = union(enum) {
    stopping,
    response: struct {
        offset: u8,
        history_result: ?*history.model.QueryResult,
    },
    resync,
    clipboard,
    proxy_status,
    agent_revision: u64,
    system_metrics_revision: u64,
    workspace_list_revision: u64,
    attachment: AttachmentWork,
};

const Transaction = struct {
    ticket: u64,
    effect: Effect,
};

const Phase = union(enum) {
    ready,
    prepared: Transaction,
    in_flight: Completion,
    closed,
};

pub const Delivery = struct {
    send_buffer: []u8,
    responses: ResponseQueue = .{},
    phase: Phase = .ready,
    next_ticket: u64 = 1,
    next_attachment: usize = 0,
    close_after_reply: bool = false,
    stopping_pending: bool = false,
    runtime_state_requested: bool = false,
    proxy_status_sent: bool = false,
    agent_revision_sent: u64 = 0,
    system_metrics_revision_sent: u64 = 0,
    workspace_list_revision_sent: u64 = 0,
    clipboard_storage: [schema.max_clipboard_bytes]u8 = undefined,
    clipboard_len: u32 = 0,
    clipboard_pane: schema.PaneId = .invalid,
    clipboard_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator) !Delivery {
        return .{ .send_buffer = try gpa.alloc(u8, core.transport.max_frame_size) };
    }

    pub fn deinit(delivery: *Delivery, gpa: std.mem.Allocator) void {
        delivery.responses.clear();
        gpa.free(delivery.send_buffer);
    }

    pub fn close(delivery: *Delivery) void {
        delivery.phase = .closed;
        delivery.responses.clear();
    }

    pub fn enqueue(delivery: *Delivery, response: response_queue.PendingResponse) !void {
        try delivery.responses.push(response);
    }

    pub fn publishOrResync(delivery: *Delivery, response: response_queue.PendingResponse) void {
        delivery.responses.pushOrDrop(response);
    }

    pub fn requestWorkspaceResync(delivery: *Delivery, workspace: schema.WorkspaceLocation, previous_workspace: ?schema.WorkspaceId) void {
        delivery.responses.resync_workspace = workspace;
        delivery.responses.resync_previous_workspace = previous_workspace;
    }

    /// Enables level-triggered runtime projections for this client. Repeated
    /// requests retain delivered revision baselines instead of replaying them.
    ///
    /// ```zig
    /// delivery.requestRuntimeState();
    /// ```
    pub fn requestRuntimeState(delivery: *Delivery) void {
        delivery.runtime_state_requested = true;
    }

    pub fn requestStop(delivery: *Delivery) void {
        delivery.stopping_pending = true;
    }

    pub fn setCloseAfterReply(delivery: *Delivery, enabled: bool) void {
        delivery.close_after_reply = enabled;
    }

    pub fn shouldCloseAfterReply(delivery: *const Delivery) bool {
        return delivery.close_after_reply and delivery.responses.len == 0;
    }

    pub fn stopping(delivery: *const Delivery) bool {
        return delivery.stopping_pending or switch (delivery.phase) {
            .prepared => |transaction| std.meta.activeTag(transaction.effect) == .stopping,
            .in_flight => |completion| completion.stopping_delivered,
            .ready, .closed => false,
        };
    }

    pub fn queueDepth(delivery: *const Delivery) usize {
        return delivery.responses.len;
    }

    pub fn queueHighWater(delivery: *const Delivery) usize {
        return delivery.responses.high_water;
    }

    pub fn queueDropped(delivery: *const Delivery) u64 {
        return delivery.responses.dropped;
    }

    /// Replaces the pending clipboard message only when `bytes` fits the wire
    /// bound. Rejected input preserves any clipboard already awaiting delivery.
    ///
    /// ```zig
    /// if (!delivery.setClipboard(pane_id, bytes)) {
    ///     return error.ClipboardTooLarge;
    /// }
    /// ```
    pub fn setClipboard(delivery: *Delivery, pane_id: schema.PaneId, bytes: []const u8) bool {
        if (bytes.len > schema.max_clipboard_bytes) {
            return false;
        }

        std.mem.copyForwards(u8, delivery.clipboard_storage[0..bytes.len], bytes);
        delivery.clipboard_len = @intCast(bytes.len);
        delivery.clipboard_pane = pane_id;
        delivery.clipboard_pending = true;
        return true;
    }

    /// Selects and stages the highest-priority deliverable without committing
    /// its logical effect until the caller starts the socket write.
    ///
    /// ```zig
    /// const prepared = try delivery.prepare(.{ .io = io, .attachments = attachments, .sources = sources, .metrics = metrics });
    /// ```
    pub fn prepare(delivery: *Delivery, preparation: Preparation) !?Prepared {
        const sources = preparation.sources;

        std.debug.assert(delivery.phase == .ready);
        const buffer = delivery.send_buffer;
        const workspaces = sources.workspaces;

        if (delivery.stopping_pending) return delivery.stage(
            try schema.encodeRuntimeStopping(buffer),
            .stopping,
        );

        if (delivery.responses.peekManagement()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try runtime_encoder.encodeResponse(.{
                .buffer = buffer,
                .panes = sources.panes,
                .workspaces = workspaces,
                .history_result = &history_result,
            }, entry.response);
            return delivery.stage(payload, .{ .response = .{
                .offset = entry.offset,
                .history_result = history_result,
            } });
        }

        if (delivery.responses.resync_workspace) |workspace| return delivery.stage(
            try schema.encodeResyncRequired(buffer, .{
                .workspace = workspace,
                .workspace_closed = !workspaces.containsWorkspace(workspace),
                .previous_workspace = delivery.responses.resync_previous_workspace,
            }),
            .resync,
        );

        if (delivery.clipboard_pending) return delivery.stage(
            try schema.encodePaneClipboard(buffer, .{
                .pane_id = delivery.clipboard_pane,
                .bytes = delivery.clipboard_storage[0..delivery.clipboard_len],
            }),
            .clipboard,
        );

        if (delivery.runtime_state_requested and !delivery.proxy_status_sent)
            return delivery.stage(
                try schema.encodeProxyStatus(buffer, .{ .active = sources.proxy_active }),
                .proxy_status,
            );

        if (delivery.runtime_state_requested and
            delivery.agent_revision_sent < sources.agents.revision)
        {
            var entry_storage: [agent_mod.max_records]schema.AgentSnapshotEntry = undefined;
            var display_storage: [agent_mod.max_records]AgentDisplayStorage = undefined;
            const entries = sources.agents.snapshot(&entry_storage);
            var enriched_count: usize = 0;
            for (entries) |entry| {
                const pane = sources.panes.resolveConst(.{
                    .id = entry.pane_id,
                    .generation = entry.pane_generation,
                }) orelse continue;
                const pane_index = sources.panes.positionAt(pane) orelse continue;
                entry_storage[enriched_count] = entry;
                entry_storage[enriched_count].location = pane.location;
                entry_storage[enriched_count].pane_index = pane_index;
                if (workspaces.workspaceName(pane.location.workspace)) |workspace_name|
                    entry_storage[enriched_count].workspace_label = copyDisplayPrefix(
                        &display_storage[enriched_count].workspace,
                        workspace_name,
                    );
                if (workspaces.tabLabel(pane.location)) |tab_label|
                    entry_storage[enriched_count].tab_label = tab_label;
                entry_storage[enriched_count].cwd_label = shortenCwd(
                    &display_storage[enriched_count].cwd,
                    pane.cwd.slice(),
                    sources.home,
                );
                enriched_count += 1;
            }
            const revision = sources.agents.revision;
            return delivery.stage(
                try schema.encodeAgentSnapshot(buffer, .{
                    .revision = revision,
                    .entries = entry_storage[0..enriched_count],
                }),
                .{ .agent_revision = revision },
            );
        }

        if (delivery.runtime_state_requested and
            delivery.system_metrics_revision_sent < sources.system_metrics.revision)
        {
            const revision = sources.system_metrics.revision;
            if (sources.system_metrics.latest) |values| return delivery.stage(
                try schema.encodeSystemMetrics(buffer, .{
                    .revision = revision,
                    .cpu_percent = values.cpu_percent,
                    .memory_used_decigib = values.memory_used_decigib,
                    .has_battery = values.battery_percent != null,
                    .battery_percent = values.battery_percent orelse 0,
                }),
                .{ .system_metrics_revision = revision },
            );
            delivery.system_metrics_revision_sent = revision;
        }

        if (delivery.runtime_state_requested and
            delivery.workspace_list_revision_sent < workspaces.revision())
        {
            var entries: [workspace_mod.max_workspaces]schema.WorkspaceListEntry = undefined;
            const revision = workspaces.revision();
            return delivery.stage(
                try schema.encodeWorkspaceList(buffer, .{
                    .revision = revision,
                    .entries = workspaces.listEntries(&entries),
                }),
                .{ .workspace_list_revision = revision },
            );
        }

        if (try delivery.prepareAttachment(preparation, .cwd)) |prepared| {
            return prepared;
        }

        if (try delivery.prepareAttachment(preparation, .foreground)) |prepared| {
            return prepared;
        }

        if (try delivery.prepareAttachment(preparation, .cells)) |prepared| {
            return prepared;
        }

        if (try delivery.prepareAttachment(preparation, .exit)) |prepared| {
            return prepared;
        }

        if (try delivery.prepareAttachment(preparation, .graphics)) |prepared| {
            return prepared;
        }

        if (delivery.responses.peekObservation()) |entry| {
            var history_result: ?*history.model.QueryResult = null;
            const payload = try runtime_encoder.encodeResponse(.{
                .buffer = buffer,
                .panes = sources.panes,
                .workspaces = workspaces,
                .history_result = &history_result,
            }, entry.response);
            return delivery.stage(payload, .{ .response = .{
                .offset = entry.offset,
                .history_result = history_result,
            } });
        }
        return null;
    }

    /// Commits one staged delivery immediately before its socket write begins.
    ///
    /// ```zig
    /// delivery.commit(.{ .prepared = prepared, .attachments = attachments, .metrics = metrics });
    /// ```
    pub fn commit(delivery: *Delivery, operation: Commit) void {
        const prepared = operation.prepared;
        const attachments = operation.attachments;
        const metrics = operation.metrics;

        const transaction = switch (delivery.phase) {
            .prepared => |transaction| transaction,
            else => unreachable,
        };
        std.debug.assert(transaction.ticket == prepared.ticket);
        var completion: Completion = .{};
        switch (transaction.effect) {
            .stopping => {
                delivery.stopping_pending = false;
                completion.stopping_delivered = true;
            },
            .response => |response| {
                if (response.history_result) |result| result.deinit();
                delivery.responses.removeAt(response.offset);
            },
            .resync => {
                delivery.responses.resync_workspace = null;
                delivery.responses.resync_previous_workspace = null;
                if (comptime diagnostics.enabled) metrics.client_resyncs += 1;
            },
            .clipboard => delivery.clipboard_pending = false,
            .proxy_status => delivery.proxy_status_sent = true,
            .agent_revision => |revision| delivery.agent_revision_sent = revision,
            .system_metrics_revision => |revision| delivery.system_metrics_revision_sent = revision,
            .workspace_list_revision => |revision| delivery.workspace_list_revision_sent = revision,
            .attachment => |work| {
                const attachment = attachments.at(work.index) orelse unreachable;
                const effect = attachment.commitPrepared(work.prepared);
                completion.detach_pane = effect.detach_after_send;
                if (comptime diagnostics.enabled) {
                    if (effect.graphics_message) {
                        metrics.graphics_messages += 1;
                        metrics.graphics_bytes += prepared.payload.len;
                        metrics.graphics_images_sent +|= effect.graphics.images;
                        metrics.graphics_placements_sent +|= effect.graphics.placements;
                    }
                }
                delivery.next_attachment = (work.index + 1) % AttachmentStore.capacity;
            },
        }
        delivery.phase = .{ .in_flight = completion };
    }

    pub fn abort(delivery: *Delivery, prepared: Prepared) void {
        const transaction = switch (delivery.phase) {
            .prepared => |transaction| transaction,
            else => unreachable,
        };
        std.debug.assert(transaction.ticket == prepared.ticket);
        delivery.phase = .closed;
    }

    pub fn complete(delivery: *Delivery, result: anyerror!void) Completion {
        const completion = switch (delivery.phase) {
            .in_flight => |completion| completion,
            else => unreachable,
        };
        if (result) |_| {
            delivery.phase = .ready;
            return completion;
        } else |_| {
            delivery.phase = .closed;
            var failed = completion;
            failed.close_client = true;
            return failed;
        }
    }

    const Lane = enum { cwd, foreground, cells, exit, graphics };

    fn prepareAttachment(delivery: *Delivery, preparation: Preparation, lane: Lane) !?Prepared {
        const attachments = preparation.attachments;
        const buffer = delivery.send_buffer;

        var checked: usize = 0;
        while (checked < AttachmentStore.capacity) : (checked += 1) {
            const index = (delivery.next_attachment + checked) % AttachmentStore.capacity;
            const attachment = attachments.at(index) orelse continue;
            const candidate: ?attachment_mod.Attachment.Prepared = switch (lane) {
                .cwd => try attachment.prepareCwd(buffer),
                .foreground => try attachment.prepareForeground(buffer),
                .cells => try attachment.prepareNextCells(.{ .io = preparation.io, .buffer = buffer, .metrics = preparation.metrics }),
                .exit => try attachment.prepareExit(buffer),
                .graphics => graphics: {
                    const frozen = attachment.hasFrozenGraphics();
                    if (attachment.pane.ingest_pending and !frozen) break :graphics null;
                    if (attachment.pane.media.worker != null and !frozen) break :graphics null;
                    if (!attachment.hasGraphicsWork()) break :graphics null;
                    break :graphics attachment.prepareNextGraphics(.{
                        .buffer = buffer,
                        .global_credit = attachments.availableGraphicsCredit(),
                        .live_storage_available = attachment.pane.media.worker == null,
                    }) catch {
                        attachment.abandonGraphics();
                        break :graphics null;
                    };
                },
            };
            if (candidate) |attachment_prepared| return delivery.stage(
                attachment_prepared.bytes,
                .{ .attachment = .{ .index = index, .prepared = attachment_prepared } },
            );
        }
        return null;
    }

    fn stage(delivery: *Delivery, payload: []const u8, effect: Effect) Prepared {
        const ticket = delivery.next_ticket;
        delivery.next_ticket +%= 1;
        if (delivery.next_ticket == 0) delivery.next_ticket = 1;
        delivery.phase = .{ .prepared = .{ .ticket = ticket, .effect = effect } };
        return .{ .payload = payload, .ticket = ticket };
    }
};

const AgentDisplayStorage = struct {
    workspace: [schema.max_agent_workspace_label_bytes]u8 = undefined,
    cwd: [schema.max_agent_cwd_label_bytes]u8 = undefined,
};

fn copyDisplayPrefix(output: []u8, source: []const u8) []const u8 {
    if (!validDisplayText(source)) return output[0..0];
    if (source.len <= output.len) {
        @memcpy(output[0..source.len], source);
        return output[0..source.len];
    }
    const ellipsis = "…";
    if (output.len < ellipsis.len) return output[0..0];
    var end = output.len - ellipsis.len;
    while (end != 0 and isUtf8Continuation(source[end])) end -= 1;
    @memcpy(output[0..end], source[0..end]);
    @memcpy(output[end..][0..ellipsis.len], ellipsis);
    return output[0 .. end + ellipsis.len];
}

fn shortenCwd(output: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    if (!validDisplayText(path)) return output[0..0];
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
    if (output.len < ellipsis.len) return output[0..0];
    const available = output.len - ellipsis.len;
    var start = suffix.len -| available;
    while (start < suffix.len and isUtf8Continuation(suffix[start])) start += 1;
    const tail = suffix[start..];
    @memcpy(output[0..ellipsis.len], ellipsis);
    @memcpy(output[ellipsis.len..][0..tail.len], tail);
    return output[0 .. ellipsis.len + tail.len];
}

fn validDisplayText(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return false;
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
