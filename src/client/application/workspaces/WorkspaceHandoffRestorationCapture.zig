const Capture = @This();
const source_namespace = @import("workspace_handoff_restoration.zig");
const RestoreWorkspaceHandoffHandler = @import("RestoreWorkspaceHandoffHandler.zig");
sibling: source_namespace.schema.PaneId,
pending: bool = false,
failure: source_namespace.Failure = .none,
events: [4]source_namespace.Event = undefined,
event_count: usize = 0,

pub fn handler(capture: *Capture) RestoreWorkspaceHandoffHandler {
    return .{
        .effects = .{
            .context = capture,
            .show_pane_graphics = showPaneGraphics,
        },
        .snapshots = .{ .effects = .{
            .context = capture,
            .pending = tabSnapshotPending,
            .request = requestTabSnapshot,
        } },
    };
}

fn showPaneGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .show_graphics = pane_id });
    if (capture.failure == .sibling_graphics and pane_id == capture.sibling) {
        return error.GraphicsVisibilityFailed;
    }
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.snapshot_pending);

    return capture.pending;
}

fn requestTabSnapshot(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_snapshot = location });
    if (capture.failure == .snapshot) {
        return error.SnapshotRequestFailed;
    }
}

fn append(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
