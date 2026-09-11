const EffectsCapture = @This();
const source_namespace = @import("resync_required.zig");
const Effects = @import("ResyncRequiredEffects.zig");
const HandleResyncRequiredHandler = @import("HandleResyncRequiredHandler.zig");
events: [2]source_namespace.EffectEvent = undefined,
event_count: usize = 0,
forgotten_workspace: ?source_namespace.schema.WorkspaceLocation = null,
snapshot_workspace: ?source_namespace.schema.WorkspaceLocation = null,
handoff_workspace: ?source_namespace.schema.WorkspaceId = null,
fail_snapshot: bool = false,
fail_handoff: bool = false,

fn port(capture: *EffectsCapture) Effects {
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

fn record(capture: *EffectsCapture, event: source_namespace.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn forgetWorkspace(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.forget_workspace);
    capture.forgotten_workspace = workspace;
}

fn requestSnapshot(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.request_snapshot);
    capture.snapshot_workspace = workspace;

    if (capture.fail_snapshot) {
        return error.SnapshotRequestFailed;
    }
}

fn requestHandoff(context: *anyopaque, workspace: source_namespace.schema.WorkspaceId) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.request_handoff);
    capture.handoff_workspace = workspace;

    if (capture.fail_handoff) {
        return error.HandoffRequestFailed;
    }
}
