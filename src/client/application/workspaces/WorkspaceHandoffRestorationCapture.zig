const PaneIdType = @import("telar-core").PaneId;
const workspace_handoff_restoration = @import("workspace_handoff_restoration.zig");
const RestoreWorkspaceHandoffHandler = @import("RestoreWorkspaceHandoffHandler.zig");
const TabLocationType = @import("telar-core").TabLocation;
const Capture = @This();

sibling: PaneIdType,
pending: bool = false,
failure: workspace_handoff_restoration.Failure = .none,
events: [4]workspace_handoff_restoration.Event = undefined,
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

fn showPaneGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
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

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_snapshot = location });
    if (capture.failure == .snapshot) {
        return error.SnapshotRequestFailed;
    }
}

fn append(capture: *Capture, event: workspace_handoff_restoration.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const workspace_handoff_restoration.Event {
    return capture.events[0..capture.event_count];
}
