const resync_required = @import("resync_required.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ResyncRequiredEffects = @import("ResyncRequiredEffects.zig");
const HandleResyncRequiredHandler = @import("HandleResyncRequiredHandler.zig");
const EffectsCapture = @This();

events: [2]resync_required.EffectEvent = undefined,
event_count: usize = 0,
forgotten_workspace: ?WorkspaceLocationType = null,
snapshot_workspace: ?WorkspaceLocationType = null,
handoff_workspace: ?WorkspaceIdType = null,
fail_snapshot: bool = false,
fail_handoff: bool = false,

fn port(capture: *EffectsCapture) ResyncRequiredEffects {
    return .{
        .context = capture,
        .forget_workspace = forgetWorkspace,
        .request_snapshot = requestSnapshot,
        .request_handoff = requestHandoff,
    };
}

pub fn handler(capture: *EffectsCapture) HandleResyncRequiredHandler {
    return .{ .effects = capture.port() };
}

fn record(capture: *EffectsCapture, event: resync_required.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn forgetWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.forget_workspace);
    capture.forgotten_workspace = workspace;
}

fn requestSnapshot(context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.request_snapshot);
    capture.snapshot_workspace = workspace;

    if (capture.fail_snapshot) {
        return error.SnapshotRequestFailed;
    }
}

fn requestHandoff(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.request_handoff);
    capture.handoff_workspace = workspace;

    if (capture.fail_handoff) {
        return error.HandoffRequestFailed;
    }
}
