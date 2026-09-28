const localsocket = @import("localsocket");
const Workspaces = @import("../../workspace/Workspaces.zig");
const Worktrees = @import("../../workspace/Worktrees.zig");
const core = @import("telar-core");
const ReviewResult = @import("../../change_review/Result.zig");
const ResponseQueue = @import("ResponseQueue.zig");
const delivery_namespace = @import("delivery_namespace.zig");
const std = @import("std");
const response_queue = @import("response_queue.zig");
const Sources = @import("Sources.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const PathQuery = @import("../../paths/PathQuery.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const runtime_encoder = @import("encoder.zig");
const LayoutSnapshotStorage = @import("../LayoutSnapshotStorage.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Completion = @import("Completion.zig");
const PreparedType = @import("../attachment/Prepared.zig");
const Attachment = @import("../attachment/Attachment.zig");
const ForegroundProjection = @import("ForegroundProjection.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Attachments = @import("../attachment/Attachments.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Delivery = @This();

send_buffer: []u8,
responses: ResponseQueue = .{},
phase: delivery_namespace.Phase = .ready,
next_ticket: u64 = 1,
next_attachment: usize = 0,
close_after_reply: bool = false,
stopping_pending: bool = false,
runtime_state_requested: bool = false,
client_identity: core.ClientIdentity = .invalid,
client_layout_sent: bool = false,
proxy_status_sent: bool = false,
agent_revision_sent: u64 = 0,
agent_snapshot_requested: bool = false,
system_metrics_revision_sent: u64 = 0,
workspace_list_revision_sent: u64 = 0,
foregrounds_sent: [PaneStore.capacity]?ForegroundProjection = @splat(null),
clipboard_storage: [core.max_clipboard_bytes]u8 = undefined,
clipboard_len: u32 = 0,
clipboard_pane: core.PaneId = .invalid,
clipboard_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) !Delivery {
    return .{ .send_buffer = try gpa.alloc(u8, localsocket.transport.max_frame_size) };
}

pub fn deinit(self: *Delivery, gpa: std.mem.Allocator) void {
    self.responses.clear();
    gpa.free(self.send_buffer);
}

pub fn close(self: *Delivery) void {
    self.phase = .closed;
    self.responses.clear();
}

pub fn enqueue(self: *Delivery, response: response_queue.PendingResponse) !void {
    try self.responses.push(response);
}

pub fn requestWorkspaceResync(self: *Delivery, workspace: core.WorkspaceLocation, previous_workspace: ?core.WorkspaceId) void {
    self.responses.resync_workspace = workspace;
    self.responses.resync_previous_workspace = previous_workspace;
}

/// Schedules one agent snapshot for a client that holds no runtime-state
/// subscription. The snapshot is the same enriched projection UI clients
/// receive; the next delivery sends it regardless of revision baselines.
///
/// ```zig
/// delivery.requestAgentSnapshot();
/// ```
pub fn requestAgentSnapshot(self: *Delivery) void {
    self.agent_snapshot_requested = true;
}

/// Enables level-triggered runtime projections for this client. Repeated
/// requests retain delivered revision baselines instead of replaying them.
///
/// ```zig
/// try delivery.requestRuntimeState(identity);
/// ```
pub fn requestRuntimeState(self: *Delivery, identity: core.ClientIdentity) !void {
    if (identity == .invalid) {
        return error.InvalidClientIdentity;
    }
    if (self.client_identity != .invalid and self.client_identity != identity) {
        return error.ClientIdentityChanged;
    }

    self.client_identity = identity;
    self.runtime_state_requested = true;
}

pub fn requestStop(self: *Delivery) void {
    self.stopping_pending = true;
}

pub fn setCloseAfterReply(self: *Delivery, enabled: bool) void {
    self.close_after_reply = enabled;
}

pub fn shouldCloseAfterReply(self: *const Delivery) bool {
    return self.close_after_reply and self.responses.len == 0;
}

pub fn stopping(self: *const Delivery) bool {
    return self.stopping_pending or switch (self.phase) {
        .prepared => |transaction| std.meta.activeTag(transaction.effect) == .stopping,
        .in_flight => |completion| completion.stopping_delivered,
        .ready, .closed => false,
    };
}

/// Replaces the pending clipboard message only when `bytes` fits the wire
/// bound. Rejected input preserves any clipboard already awaiting delivery.
///
/// ```zig
/// if (!delivery.setClipboard(pane_id, bytes)) {
///     return error.ClipboardTooLarge;
/// }
/// ```
pub fn setClipboard(self: *Delivery, pane_id: core.PaneId, bytes: []const u8) bool {
    if (bytes.len > core.max_clipboard_bytes) {
        return false;
    }

    std.mem.copyForwards(u8, self.clipboard_storage[0..bytes.len], bytes);
    self.clipboard_len = @intCast(bytes.len);
    self.clipboard_pane = pane_id;
    self.clipboard_pending = true;
    return true;
}

/// Selects and stages the highest-priority deliverable without committing
/// its logical effect until the caller starts the socket write.
///
/// ```zig
/// const prepared = try delivery.prepare(.{ .io = io, .attachments = &model.attachments, .client = session.slot, .sources = sources, .metrics = metrics });
/// ```
pub fn prepare(self: *Delivery, preparation: Preparation) !?Prepared {
    const sources = preparation.sources;

    std.debug.assert(self.phase == .ready);
    const buffer = self.send_buffer;
    const workspaces = sources.workspaces;

    if (self.stopping_pending) {
        return self.stage(
            try core.encodeRuntimeStopping(buffer),
            .stopping,
        );
    }

    if (self.responses.peekManagement()) |entry| {
        var history_result: ?*QueryResult = null;
        var history_output: ?*OutputResult = null;
        var history_stats: ?*StatsResult = null;
        var change_review: ?*ReviewResult = null;
        var path_results: ?*PathQuery = null;
        const payload = try runtime_encoder.encodeResponse(.{
            .buffer = buffer,
            .panes = sources.panes,
            .workspaces = workspaces,
            .history_result = &history_result,
            .history_output = &history_output,
            .history_stats = &history_stats,
            .change_review = &change_review,
            .path_results = &path_results,
        }, entry.response);
        return self.stage(payload, .{ .response = .{
            .offset = entry.offset,
            .history_result = history_result,
            .history_output = history_output,
            .history_stats = history_stats,
            .change_review = change_review,
            .path_results = path_results,
        } });
    }

    if (self.responses.resync_workspace) |workspace| {
        return self.stage(
            try core.encodeResyncRequired(buffer, .{
                .workspace = workspace,
                .workspace_closed = !workspaces.containsWorkspace(workspace),
                .previous_workspace = self.responses.resync_previous_workspace,
            }),
            .resync,
        );
    }

    if (self.clipboard_pending) {
        return self.stage(
            try core.encodePaneClipboard(buffer, .{
                .pane_id = self.clipboard_pane,
                .bytes = self.clipboard_storage[0..self.clipboard_len],
            }),
            .clipboard,
        );
    }

    if (self.runtime_state_requested and !self.client_layout_sent) {
        var storage: LayoutSnapshotStorage = .{};
        const snapshot: core.ClientLayoutSnapshot = if (sources.client_layouts) |layouts|
            layouts.snapshot(self.client_identity, sources.panes, workspaces, &storage)
        else
            .{ .restored = false };
        return self.stage(
            try core.encodeClientLayoutSnapshot(buffer, snapshot),
            .client_layout,
        );
    }

    if (self.runtime_state_requested and !self.proxy_status_sent) {
        return self.stage(
            try core.encodeProxyStatus(buffer, .{
                .active = sources.proxy_active,
                .scope = sources.proxy_scope,
                .system_trusted = sources.proxy_system_trusted,
            }),
            .proxy_status,
        );
    }

    // Cells win over every periodic or metadata lane. With one message in
    // flight per client, anything sent ahead of a dirty pane costs the
    // keystroke echo a whole round trip.
    const pending = pendingAttachments(preparation);
    if (try self.prepareAttachment(preparation, .cells, pending)) |prepared| {
        return prepared;
    }

    if (self.agent_snapshot_requested or (self.runtime_state_requested and
        self.agent_revision_sent < sources.agent_revision))
    {
        const revision = sources.agent_revision;
        return self.stage(
            try core.encodeAgentSnapshot(buffer, .{
                .revision = revision,
                .entries = sources.agent_entries,
            }),
            .{ .agent_revision = revision },
        );
    }

    if (self.runtime_state_requested) {
        if (try self.prepareAttachment(preparation, .review, pending)) |prepared| {
            return prepared;
        }
    }

    if (self.runtime_state_requested and
        self.system_metrics_revision_sent < sources.system_metrics.revision)
    {
        const revision = sources.system_metrics.revision;
        if (sources.system_metrics.latest) |values| {
            return self.stage(
                try core.encodeSystemMetrics(buffer, .{
                    .revision = revision,
                    .cpu_percent = values.cpu_percent,
                    .memory_used_decigib = values.memory_used_decigib,
                    .has_battery = values.battery_percent != null,
                    .battery_percent = values.battery_percent orelse 0,
                    .cpu_count = values.cpu_count,
                    .memory_total_decigib = values.memory_total_decigib,
                }),
                .{ .system_metrics_revision = revision },
            );
        }
        self.system_metrics_revision_sent = revision;
    }

    if (self.runtime_state_requested and
        self.workspace_list_revision_sent < workspaces.revision)
    {
        var entries: [Workspaces.capacity]core.WorkspaceListEntry = undefined;
        var worktree_entries: [Worktrees.capacity]core.WorktreeListEntry = undefined;
        const revision = workspaces.revision;
        return self.stage(
            try core.encodeWorkspaceList(buffer, .{
                .revision = revision,
                .entries = workspaces.listEntries(&entries),
                .worktrees = sources.worktrees.listEntries(&worktree_entries),
            }),
            .{ .workspace_list_revision = revision },
        );
    }

    if (try self.prepareAttachment(preparation, .cwd, pending)) |prepared| {
        return prepared;
    }

    if (try self.prepareAttachment(preparation, .foreground, pending)) |prepared| {
        return prepared;
    }

    if (self.runtime_state_requested) {
        if (try self.prepareForeground(preparation)) |prepared| {
            return prepared;
        }
    }

    if (try self.prepareAttachment(preparation, .title, pending)) |prepared| {
        return prepared;
    }

    if (try self.prepareAttachment(preparation, .progress, pending)) |prepared| {
        return prepared;
    }

    if (try self.prepareAttachment(preparation, .exit, pending)) |prepared| {
        return prepared;
    }

    if (try self.prepareAttachment(preparation, .graphics, pending)) |prepared| {
        return prepared;
    }

    if (self.responses.peekObservation()) |entry| {
        var history_result: ?*QueryResult = null;
        var history_output: ?*OutputResult = null;
        var history_stats: ?*StatsResult = null;
        var change_review: ?*ReviewResult = null;
        var path_results: ?*PathQuery = null;
        const payload = try runtime_encoder.encodeResponse(.{
            .buffer = buffer,
            .panes = sources.panes,
            .workspaces = workspaces,
            .history_result = &history_result,
            .history_output = &history_output,
            .history_stats = &history_stats,
            .change_review = &change_review,
            .path_results = &path_results,
        }, entry.response);
        return self.stage(payload, .{ .response = .{
            .offset = entry.offset,
            .history_result = history_result,
            .history_output = history_output,
            .history_stats = history_stats,
            .change_review = change_review,
            .path_results = path_results,
        } });
    }
    return null;
}

/// Commits one staged delivery immediately before its socket write begins.
///
/// ```zig
/// delivery.commit(.{ .prepared = prepared, .attachments = &model.attachments, .client = session.slot, .metrics = metrics });
/// ```
pub fn commit(self: *Delivery, operation: Commit) void {
    const prepared = operation.prepared;
    const attachments = operation.attachments;
    const metrics = operation.metrics;

    const transaction = switch (self.phase) {
        .prepared => |transaction| transaction,
        else => unreachable,
    };
    std.debug.assert(transaction.ticket == prepared.ticket);
    var completion: Completion = .{};
    switch (transaction.effect) {
        .stopping => {
            self.stopping_pending = false;
            completion.stopping_delivered = true;
        },
        .response => |response| {
            if (response.history_result) |result| {
                result.deinit();
            }
            if (response.history_output) |result| {
                result.deinit();
            }
            if (response.history_stats) |result| {
                result.deinit();
            }
            if (response.change_review) |result| {
                result.deinit();
            }
            if (response.path_results) |query| {
                query.destroy();
            }
            self.responses.removeAt(response.offset);
        },
        .resync => {
            self.responses.resync_workspace = null;
            self.responses.resync_previous_workspace = null;
            if (comptime core.enabled) {
                metrics.client_resyncs += 1;
            }
        },
        .clipboard => self.clipboard_pending = false,
        .client_layout => self.client_layout_sent = true,
        .proxy_status => self.proxy_status_sent = true,
        .agent_revision => |revision| {
            self.agent_revision_sent = revision;
            self.agent_snapshot_requested = false;
        },
        .system_metrics_revision => |revision| self.system_metrics_revision_sent = revision,
        .workspace_list_revision => |revision| self.workspace_list_revision_sent = revision,
        .foreground => |projection| self.foregrounds_sent[projection.slot] = projection,
        .attachment => |work| {
            const attachment = attachments.at(operation.client, work.index) orelse unreachable;
            const effect = attachment.commitPrepared(work.prepared);
            completion.detach_pane = effect.detach_after_send;
            if (comptime core.enabled) {
                if (effect.graphics_message) {
                    metrics.graphics_messages += 1;
                    metrics.graphics_bytes += prepared.payload.len;
                    metrics.graphics_images_sent +|= effect.graphics.images;
                    metrics.graphics_placements_sent +|= effect.graphics.placements;
                    metrics.graphics_stage_blocked +|= effect.graphics.stage_blocked;
                    metrics.graphics_transfers_adopted +|= effect.graphics.adopted;
                    metrics.graphics_freeze.merge(effect.graphics.freeze);
                }
            }
            self.next_attachment = (work.index + 1) % Attachments.capacity;
        },
    }
    self.phase = .{ .in_flight = completion };
}

pub fn abort(self: *Delivery, prepared: Prepared) void {
    const transaction = switch (self.phase) {
        .prepared => |transaction| transaction,
        else => unreachable,
    };
    std.debug.assert(transaction.ticket == prepared.ticket);
    self.phase = .closed;
}

pub fn complete(self: *Delivery, result: anyerror!void) Completion {
    const completion = switch (self.phase) {
        .in_flight => |completion| completion,
        else => unreachable,
    };
    if (result) |_| {
        self.phase = .ready;
        return completion;
    } else |_| {
        self.phase = .closed;
        var failed = completion;
        failed.close_client = true;
        return failed;
    }
}

const Lane = enum { cwd, foreground, title, progress, review, cells, exit, graphics };

fn prepareForeground(self: *Delivery, preparation: Preparation) !?Prepared {
    for (preparation.sources.panes.items, 0..) |slot, index| {
        const pane = slot orelse continue;
        if (!pane.launch_state.discoverable() or pane.close_requested or pane.exit != null) {
            continue;
        }

        const attached = pane.observers & Attachments.observer(preparation.client) != 0;
        if (std.debug.runtime_safety) {
            std.debug.assert(attached == (preparation.attachments.find(preparation.client, pane.id) != null));
        }

        if (attached) {
            continue;
        }

        const projection: ForegroundProjection = .{ .slot = index, .key = pane.key(), .revision = pane.foreground_revision };
        if (self.foregrounds_sent[index]) |previous| {
            if (std.meta.eql(previous, projection)) {
                continue;
            }
        }

        return self.stage(try core.encodePaneForeground(self.send_buffer, .{
            .pane_id = pane.id,
            .name = pane.agent_process_cache.name(),
        }), .{ .foreground = projection });
    }

    return null;
}

/// Marks the client's attachments for which some lane could publish, in one
/// visit per attachment, so each lane skips the idle ones.
fn pendingAttachments(preparation: Preparation) u64 {
    comptime std.debug.assert(Attachments.capacity == @bitSizeOf(u64));

    var pending: u64 = 0;
    for (&preparation.attachments.record[preparation.client], 0..) |slot, index| {
        const attachment = slot orelse continue;
        if (attachment.hasDelivery()) {
            pending |= @as(u64, 1) << @intCast(index);
        }
    }

    return pending;
}

/// Offers the lane to the pending attachments only, in round-robin order
/// from the attachment after the last one delivered.
fn prepareAttachment(self: *Delivery, preparation: Preparation, lane: Lane, pending: u64) !?Prepared {
    if (std.debug.runtime_safety) {
        try self.assertIdle(preparation, lane, pending);
    }

    const start: u6 = @intCast(self.next_attachment);
    var remaining = std.math.rotr(u64, pending, start);
    while (remaining != 0) {
        const offset = @ctz(remaining);
        remaining &= remaining - 1;
        const index = (@as(usize, start) + offset) % Attachments.capacity;
        const attachment = preparation.attachments.at(preparation.client, index).?;

        if (try self.candidate(preparation, attachment, lane)) |attachment_prepared| {
            return self.stage(
                attachment_prepared.bytes,
                .{ .attachment = .{ .index = index, .prepared = attachment_prepared } },
            );
        }
    }

    return null;
}

/// Proves the skip exact in safe builds: every attachment left out of the
/// pending mask yields nothing on this lane and changes nothing.
fn assertIdle(self: *Delivery, preparation: Preparation, lane: Lane, pending: u64) !void {
    for (&preparation.attachments.record[preparation.client], 0..) |slot, index| {
        const attachment = slot orelse continue;
        if (pending & (@as(u64, 1) << @intCast(index)) == 0) {
            std.debug.assert(try self.candidate(preparation, attachment, lane) == null);
        }
    }
}

fn candidate(self: *Delivery, preparation: Preparation, attachment: *Attachment, lane: Lane) !?PreparedType {
    const buffer = self.send_buffer;
    return switch (lane) {
        .cwd => try attachment.prepareCwd(buffer),
        .foreground => try attachment.prepareForeground(buffer),
        .title => try attachment.prepareTitle(buffer),
        .progress => try attachment.prepareProgress(buffer),
        .review => try attachment.prepareReview(buffer),
        .cells => try attachment.prepareNextCells(.{ .io = preparation.io, .buffer = buffer, .metrics = preparation.metrics }),
        .exit => try attachment.prepareExit(buffer),
        .graphics => graphics: {
            const frozen = attachment.hasFrozenGraphics();
            if (attachment.pane.ingest_pending and !frozen) {
                break :graphics null;
            }
            if (!attachment.hasGraphicsWork()) {
                break :graphics null;
            }
            if (attachment.pane.media.worker != null and !frozen) {
                if (comptime core.enabled) {
                    preparation.metrics.graphics_stage_deferred +|= 1;
                }
                break :graphics null;
            }
            break :graphics attachment.prepareNextGraphics(.{
                .buffer = buffer,
                .global_credit = preparation.attachments.availableGraphicsCredit(preparation.client),
                .live_storage_available = attachment.pane.media.worker == null,
            }) catch {
                attachment.abandonGraphics();
                break :graphics null;
            };
        },
    };
}

pub fn stage(self: *Delivery, payload: []const u8, effect: delivery_namespace.Effect) Prepared {
    const ticket = self.next_ticket;
    self.next_ticket +%= 1;
    if (self.next_ticket == 0) {
        self.next_ticket = 1;
    }
    self.phase = .{ .prepared = .{ .ticket = ticket, .effect = effect } };
    return .{ .payload = payload, .ticket = ticket };
}

const Commit = struct {
    prepared: Prepared,
    attachments: *Attachments,
    client: usize,
    metrics: *RuntimeMetrics,
};

const Preparation = struct {
    io: std.Io,
    attachments: *Attachments,
    client: usize,
    sources: Sources,
    metrics: *RuntimeMetrics,
};

const Prepared = struct {
    payload: []const u8,
    ticket: u64,
};
