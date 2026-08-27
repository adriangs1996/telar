//! Runtime protocol projection from authoritative state.

const std = @import("std");
const core = @import("telar-core");
const damage = @import("../pane/root.zig").damage;
const graphics_sync = @import("graphics_sync.zig");
const history = @import("../history/root.zig");
const pane_mod = @import("../pane/root.zig");
const response_queue = @import("response_queue.zig");
const telemetry = @import("telemetry.zig");
const workspace = @import("workspace.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const Attachment = graphics_sync.Attachment;
const PaneStore = pane_mod.PaneStore;
const PendingResponse = response_queue.PendingResponse;
const RuntimeMetrics = telemetry.RuntimeMetrics;
const WorkspaceStore = workspace.WorkspaceStore;
const max_panes = pane_mod.max_panes;
const max_tabs_per_workspace = workspace.max_tabs_per_workspace;

pub fn encodeFrame(
    io: Io,
    buffer: []u8,
    attachment: *Attachment,
    force_snapshot: bool,
    metrics: *RuntimeMetrics,
) !?[]const u8 {
    const pane = attachment.pane;
    // A child mid synchronized-output block (DEC 2026) has not finished its
    // frame; holding keeps intermediate cursor positions and torn repaints
    // off every client's screen. Forced snapshots still go out: an attach
    // cannot wait on a child, and the next incremental frame settles it.
    if (!force_snapshot and pane.holdFrames(io)) return null;
    const started = diagnostics.now(io);
    if (pane.render_pending) try pane.render(false);
    const projection = try attachment.project(force_snapshot);
    const source = projection.buffer;
    var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
    var snapshot = force_snapshot;
    const diff = if (snapshot)
        damage.Diff{}
    else
        damage.collectSpans(
            source.cells,
            attachment.acknowledged.cells,
            source.w,
            projection.damaged_rows,
            &span_storage,
        );
    var span_count = diff.span_count;
    snapshot = snapshot or diff.snapshot_required;

    const cursor_changed = !std.meta.eql(projection.cursor, attachment.acknowledged_cursor);
    const mouse_changed = !std.meta.eql(pane.mouse, attachment.acknowledged_mouse);
    const input_modes_changed = !std.meta.eql(
        pane.input_modes,
        attachment.acknowledged_input_modes,
    );
    const scroll_changed = !std.meta.eql(projection.scroll, attachment.acknowledged_scroll);
    if (!snapshot and span_count == 0 and !cursor_changed and !mouse_changed and
        !input_modes_changed and !scroll_changed)
    {
        if (comptime diagnostics.enabled) {
            metrics.noop_frames += 1;
            metrics.damaged_rows += diff.damaged_rows;
            metrics.diff_scanned_cells += diff.scanned_cells;
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
            metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
        }
        return null;
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = source.cells };
        span_count = 1;
    }

    const frame_id = attachment.next_frame_id;
    attachment.next_frame_id += 1;
    const payload = try schema.encodePaneFrame(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else attachment.acknowledged_frame_id,
        .cols = source.w,
        .rows = source.h,
        .cursor = projection.cursor,
        .mouse = pane.mouse,
        .input_modes = pane.input_modes,
        .scroll = projection.scroll,
        .spans = span_storage[0..span_count],
    });
    if (snapshot) {
        @memcpy(attachment.acknowledged.cells, source.cells);
    } else {
        for (span_storage[0..span_count]) |span| {
            const start: usize = @intCast(span.start);
            @memcpy(attachment.acknowledged.cells[start..][0..span.cells.len], span.cells);
        }
    }
    attachment.acknowledged_cursor = projection.cursor;
    attachment.acknowledged_mouse = pane.mouse;
    attachment.acknowledged_input_modes = pane.input_modes;
    attachment.acknowledged_scroll = projection.scroll;
    if (projection.buffer == &attachment.projected)
        @memset(attachment.projected_damage, false);
    attachment.observed_cell_revision = pane.cell_revision;
    attachment.outstanding_frame_id = frame_id;
    attachment.frame_sent_ns = diagnostics.now(io);
    if (comptime diagnostics.enabled) {
        var cell_count: u64 = 0;
        for (span_storage[0..span_count]) |span| cell_count += span.cells.len;
        metrics.frames += 1;
        metrics.frame_bytes += payload.len;
        metrics.frame_cells += cell_count;
        metrics.frame_spans += span_count;
        if (snapshot) metrics.snapshots += 1;
        if (!snapshot and span_count == 0) metrics.cursor_only_frames += 1;
        metrics.damaged_rows += diff.damaged_rows;
        metrics.diff_scanned_cells += diff.scanned_cells;
        if (!snapshot) {
            metrics.coalesced_spans += diff.coalesced_spans;
            metrics.bridged_cells += diff.bridged_cells;
            metrics.coalesced_bytes_saved += diff.bytes_saved;
        }
        metrics.encode.observe(diagnostics.elapsed(started, diagnostics.now(io)));
    }
    return payload;
}

/// Encodes one queued response against the *current* stores. A response can
/// outlive what it describes - the workspace of a queued snapshot may close
/// before the send slot frees up - and encoding must then degrade to a
/// `request_failed` reply, never to an error that tears the client down.
pub fn encodeResponse(
    buffer: []u8,
    response: *PendingResponse,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    history_result: *?*history.model.QueryResult,
) ![]const u8 {
    var descriptor_storage: [max_panes]schema.PaneDescriptor = undefined;
    var tab_storage: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    var history_storage: [history.model.max_results]schema.HistoryEntry = undefined;
    return switch (response.*) {
        .request_failed => |failure| try schema.encodeRequestFailed(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        }),
        .pane_opened => |opened| try schema.encodePaneOpened(buffer, opened),
        .tab_snapshot => |snapshot| try schema.encodeTabSnapshot(buffer, .{
            .request_id = snapshot.request_id,
            .location = snapshot.location,
            .panes = panes.descriptorsAt(snapshot.location, &descriptor_storage),
        }),
        .workspace_snapshot => |snapshot| payload: {
            const descriptor_snapshot = workspaces.descriptors(
                snapshot.workspace,
                panes,
                &tab_storage,
            ) orelse
                break :payload try schema.encodeRequestFailed(buffer, .{
                    .request_id = snapshot.request_id,
                    .code = .workspace_not_found,
                    .message = "workspace closed before its snapshot was sent",
                });
            break :payload try schema.encodeWorkspaceSnapshot(buffer, .{
                .request_id = snapshot.request_id,
                .workspace = snapshot.workspace,
                .name = descriptor_snapshot.name,
                .tabs = descriptor_snapshot.tabs,
            });
        },
        .tab_created => |*created| try schema.encodeTabCreated(buffer, .{
            .request_id = created.request_id,
            .location = created.location,
            .position = created.position,
            .label = created.labelSlice(),
            .root_pane_id = created.root_pane_id,
        }),
        .tab_renamed => |*renamed| try schema.encodeTabRenamed(buffer, .{
            .request_id = renamed.request_id,
            .location = renamed.location,
            .label = renamed.labelSlice(),
        }),
        .tab_closed => |closed| try schema.encodeTabClosed(buffer, closed),
        .tab_moved => |moved| try schema.encodeTabMoved(buffer, moved),
        .notification => |*notification| try schema.encodeNotification(
            buffer,
            notification.view(),
        ),
        .notification_shown => |shown| try schema.encodeNotificationShown(buffer, shown),
        .agent_sound => |sound| try schema.encodeAgentSound(buffer, sound),
        .history_result => |result| payload: {
            history_result.* = result;
            break :payload try encodeHistoryResult(buffer, result, &history_storage);
        },
    };
}

fn encodeHistoryResult(
    buffer: []u8,
    result: *const history.model.QueryResult,
    storage: *[history.model.max_results]schema.HistoryEntry,
) ![]const u8 {
    std.debug.assert(result.entries.len <= storage.len);
    for (result.entries, 0..) |entry, index| {
        storage[index] = .{
            .id = entry.id,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .exit_code = entry.exit_code,
            .status = switch (entry.status) {
                .completed => .completed,
                .interrupted => .interrupted,
            },
            .command = entry.command,
            .cwd = entry.cwd,
            .workspace_path = entry.workspace_path,
        };
    }
    return schema.encodeHistoryResults(buffer, .{
        .request_id = result.request_id,
        .entries = storage[0..result.entries.len],
    });
}
