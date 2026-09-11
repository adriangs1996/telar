const ResponseQueueType = @import("ResponseQueue.zig");
const delivery_namespace = @import("delivery_namespace.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;
const max_clipboard_bytes_module = @import("telar-core").max_clipboard_bytes;
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const max_frame_size_module = @import("telar-core").max_frame_size;
const response_queue = @import("response_queue.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Preparation = @import("Preparation.zig");
const Prepared = @import("Prepared.zig");
const encodeRuntimeStopping_module = @import("telar-core").encodeRuntimeStopping;
const QueryResultType = @import("../../history/QueryResult.zig");
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const runtime_encoder = @import("encoder.zig");
const encodeResyncRequired_module = @import("telar-core").encodeResyncRequired;
const encodePaneClipboard_module = @import("telar-core").encodePaneClipboard;
const SnapshotStorageType = @import("../application/SnapshotStorage.zig");
const ClientLayoutSnapshotType = @import("telar-core").ClientLayoutSnapshot;
const encodeClientLayoutSnapshot_module = @import("telar-core").encodeClientLayoutSnapshot;
const encodeProxyStatus_module = @import("telar-core").encodeProxyStatus;
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const AgentDisplayStorage = @import("AgentDisplayStorage.zig");
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const encodeAgentSnapshot_module = @import("telar-core").encodeAgentSnapshot;
const encodeSystemMetrics_module = @import("telar-core").encodeSystemMetrics;
const state_support = @import("../../workspace/state_support.zig");
const WorkspaceListEntryType = @import("telar-core").WorkspaceListEntry;
const encodeWorkspaceList_module = @import("telar-core").encodeWorkspaceList;
const Commit = @import("Commit.zig");
const Completion = @import("Completion.zig");
const enabled_module = @import("telar-core").enabled;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PreparedType = @import("../attachment/Prepared.zig");
const Delivery = @This();

send_buffer: []u8,
responses: ResponseQueueType = .{},
phase: delivery_namespace.Phase = .ready,
next_ticket: u64 = 1,
next_attachment: usize = 0,
close_after_reply: bool = false,
stopping_pending: bool = false,
runtime_state_requested: bool = false,
client_identity: ClientIdentityType = .invalid,
client_layout_sent: bool = false,
proxy_status_sent: bool = false,
agent_revision_sent: u64 = 0,
agent_snapshot_requested: bool = false,
system_metrics_revision_sent: u64 = 0,
workspace_list_revision_sent: u64 = 0,
clipboard_storage: [max_clipboard_bytes_module]u8 = undefined,
clipboard_len: u32 = 0,
clipboard_pane: PaneIdType = .invalid,
clipboard_pending: bool = false,

pub fn init(gpa: std.mem.Allocator) !Delivery {
    return .{ .send_buffer = try gpa.alloc(u8, max_frame_size_module) };
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

pub fn requestWorkspaceResync(delivery: *Delivery, workspace: WorkspaceLocationType, previous_workspace: ?WorkspaceIdType) void {
    delivery.responses.resync_workspace = workspace;
    delivery.responses.resync_previous_workspace = previous_workspace;
}

/// Schedules one agent snapshot for a client that holds no runtime-state
/// subscription. The snapshot is the same enriched projection UI clients
/// receive; the next delivery sends it regardless of revision baselines.
///
/// ```zig
/// delivery.requestAgentSnapshot();
/// ```
pub fn requestAgentSnapshot(delivery: *Delivery) void {
    delivery.agent_snapshot_requested = true;
}

/// Enables level-triggered runtime projections for this client. Repeated
/// requests retain delivered revision baselines instead of replaying them.
///
/// ```zig
/// try delivery.requestRuntimeState(identity);
/// ```
pub fn requestRuntimeState(delivery: *Delivery, identity: ClientIdentityType) !void {
    if (identity == .invalid) {
        return error.InvalidClientIdentity;
    }
    if (delivery.client_identity != .invalid and delivery.client_identity != identity) {
        return error.ClientIdentityChanged;
    }

    delivery.client_identity = identity;
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
pub fn setClipboard(delivery: *Delivery, pane_id: PaneIdType, bytes: []const u8) bool {
    if (bytes.len > max_clipboard_bytes_module) {
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

    if (delivery.stopping_pending) {
        return delivery.stage(
            try encodeRuntimeStopping_module(buffer),
            .stopping,
        );
    }

    if (delivery.responses.peekManagement()) |entry| {
        var history_result: ?*QueryResultType = null;
        var history_output: ?*OutputResultType = null;
        var history_stats: ?*StatsResultType = null;
        const payload = try runtime_encoder.encodeResponse(.{
            .buffer = buffer,
            .panes = sources.panes,
            .workspaces = workspaces,
            .history_result = &history_result,
            .history_output = &history_output,
            .history_stats = &history_stats,
        }, entry.response);
        return delivery.stage(payload, .{ .response = .{
            .offset = entry.offset,
            .history_result = history_result,
            .history_output = history_output,
            .history_stats = history_stats,
        } });
    }

    if (delivery.responses.resync_workspace) |workspace| {
        return delivery.stage(
            try encodeResyncRequired_module(buffer, .{
                .workspace = workspace,
                .workspace_closed = !workspaces.containsWorkspace(workspace),
                .previous_workspace = delivery.responses.resync_previous_workspace,
            }),
            .resync,
        );
    }

    if (delivery.clipboard_pending) {
        return delivery.stage(
            try encodePaneClipboard_module(buffer, .{
                .pane_id = delivery.clipboard_pane,
                .bytes = delivery.clipboard_storage[0..delivery.clipboard_len],
            }),
            .clipboard,
        );
    }

    if (delivery.runtime_state_requested and !delivery.client_layout_sent) {
        var storage: SnapshotStorageType = .{};
        const snapshot: ClientLayoutSnapshotType = if (sources.client_layouts) |store|
            store.snapshot(.{
                .identity = delivery.client_identity,
                .sources = .{ .panes = sources.panes, .workspaces = workspaces },
            }, &storage)
        else
            .{ .restored = false };
        return delivery.stage(
            try encodeClientLayoutSnapshot_module(buffer, snapshot),
            .client_layout,
        );
    }

    if (delivery.runtime_state_requested and !delivery.proxy_status_sent) {
        return delivery.stage(
            try encodeProxyStatus_module(buffer, .{
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
    if (try delivery.prepareAttachment(preparation, .cells)) |prepared| {
        return prepared;
    }

    if (delivery.agent_snapshot_requested or (delivery.runtime_state_requested and
        delivery.agent_revision_sent < sources.agents.revision))
    {
        var entry_storage: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
        var display_storage: [max_agent_snapshot_entries]AgentDisplayStorage = undefined;
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
            if (entry.provider != .unknown) {
                entry_storage[enriched_count].provider_name = sources.manifests.providerName(entry.provider);
                entry_storage[enriched_count].display_name = sources.manifests.displayName(entry.provider);
                entry_storage[enriched_count].icon = sources.manifests.icon(entry.provider);
                entry_storage[enriched_count].attachments = sources.manifests.attachments(entry.provider);
            }
            entry_storage[enriched_count].pane_index = pane_index;
            if (workspaces.workspaceName(pane.location.workspace)) |workspace_name| {
                entry_storage[enriched_count].workspace_label = delivery_namespace.copyDisplayPrefix(
                    &display_storage[enriched_count].workspace,
                    workspace_name,
                );
            }
            if (workspaces.tabLabel(pane.location)) |tab_label| {
                entry_storage[enriched_count].tab_label = tab_label;
            }
            if (entry.title_source == .telar and pane.title.len != 0) {
                entry_storage[enriched_count].session_title = delivery_namespace.truncateUtf8(
                    pane.title.slice(),
                    max_agent_session_title_bytes_module,
                );
                entry_storage[enriched_count].title_source = .terminal;
            } else if (entry.title_source == .telar) {
                entry_storage[enriched_count].session_title = sources.manifests.placeholderTitle(
                    entry.provider,
                    &display_storage[enriched_count].placeholder,
                );
            }
            entry_storage[enriched_count].cwd_label = delivery_namespace.shortenCwd(
                &display_storage[enriched_count].cwd,
                pane.cwd.slice(),
                sources.home,
            );
            enriched_count += 1;
        }
        const revision = sources.agents.revision;
        return delivery.stage(
            try encodeAgentSnapshot_module(buffer, .{
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
        if (sources.system_metrics.latest) |values| {
            return delivery.stage(
                try encodeSystemMetrics_module(buffer, .{
                    .revision = revision,
                    .cpu_percent = values.cpu_percent,
                    .memory_used_decigib = values.memory_used_decigib,
                    .has_battery = values.battery_percent != null,
                    .battery_percent = values.battery_percent orelse 0,
                }),
                .{ .system_metrics_revision = revision },
            );
        }
        delivery.system_metrics_revision_sent = revision;
    }

    if (delivery.runtime_state_requested and
        delivery.workspace_list_revision_sent < workspaces.revision())
    {
        var entries: [state_support.max_workspaces]WorkspaceListEntryType = undefined;
        const revision = workspaces.revision();
        return delivery.stage(
            try encodeWorkspaceList_module(buffer, .{
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

    if (try delivery.prepareAttachment(preparation, .title)) |prepared| {
        return prepared;
    }

    if (try delivery.prepareAttachment(preparation, .progress)) |prepared| {
        return prepared;
    }

    if (try delivery.prepareAttachment(preparation, .exit)) |prepared| {
        return prepared;
    }

    if (try delivery.prepareAttachment(preparation, .graphics)) |prepared| {
        return prepared;
    }

    if (delivery.responses.peekObservation()) |entry| {
        var history_result: ?*QueryResultType = null;
        var history_output: ?*OutputResultType = null;
        var history_stats: ?*StatsResultType = null;
        const payload = try runtime_encoder.encodeResponse(.{
            .buffer = buffer,
            .panes = sources.panes,
            .workspaces = workspaces,
            .history_result = &history_result,
            .history_output = &history_output,
            .history_stats = &history_stats,
        }, entry.response);
        return delivery.stage(payload, .{ .response = .{
            .offset = entry.offset,
            .history_result = history_result,
            .history_output = history_output,
            .history_stats = history_stats,
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
            if (response.history_result) |result| {
                result.deinit();
            }
            if (response.history_output) |result| {
                result.deinit();
            }
            if (response.history_stats) |result| {
                result.deinit();
            }
            delivery.responses.removeAt(response.offset);
        },
        .resync => {
            delivery.responses.resync_workspace = null;
            delivery.responses.resync_previous_workspace = null;
            if (comptime enabled_module) {
                metrics.client_resyncs += 1;
            }
        },
        .clipboard => delivery.clipboard_pending = false,
        .client_layout => delivery.client_layout_sent = true,
        .proxy_status => delivery.proxy_status_sent = true,
        .agent_revision => |revision| {
            delivery.agent_revision_sent = revision;
            delivery.agent_snapshot_requested = false;
        },
        .system_metrics_revision => |revision| delivery.system_metrics_revision_sent = revision,
        .workspace_list_revision => |revision| delivery.workspace_list_revision_sent = revision,
        .attachment => |work| {
            const attachment = attachments.at(work.index) orelse unreachable;
            const effect = attachment.commitPrepared(work.prepared);
            completion.detach_pane = effect.detach_after_send;
            if (comptime enabled_module) {
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
            delivery.next_attachment = (work.index + 1) % max_panes_per_tab;
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

const Lane = enum { cwd, foreground, title, progress, cells, exit, graphics };

fn prepareAttachment(delivery: *Delivery, preparation: Preparation, lane: Lane) !?Prepared {
    const attachments = preparation.attachments;
    const buffer = delivery.send_buffer;

    var checked: usize = 0;
    while (checked < max_panes_per_tab) : (checked += 1) {
        const index = (delivery.next_attachment + checked) % max_panes_per_tab;
        const attachment = attachments.at(index) orelse continue;
        const candidate: ?PreparedType = switch (lane) {
            .cwd => try attachment.prepareCwd(buffer),
            .foreground => try attachment.prepareForeground(buffer),
            .title => try attachment.prepareTitle(buffer),
            .progress => try attachment.prepareProgress(buffer),
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
                    if (comptime enabled_module) {
                        preparation.metrics.graphics_stage_deferred +|= 1;
                    }
                    break :graphics null;
                }
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
        if (candidate) |attachment_prepared| {
            return delivery.stage(
                attachment_prepared.bytes,
                .{ .attachment = .{ .index = index, .prepared = attachment_prepared } },
            );
        }
    }
    return null;
}

pub fn stage(delivery: *Delivery, payload: []const u8, effect: delivery_namespace.Effect) Prepared {
    const ticket = delivery.next_ticket;
    delivery.next_ticket +%= 1;
    if (delivery.next_ticket == 0) {
        delivery.next_ticket = 1;
    }
    delivery.phase = .{ .prepared = .{ .ticket = ticket, .effect = effect } };
    return .{ .payload = payload, .ticket = ticket };
}
