const ModelType = @import("../../model/Model.zig");
const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");
const workspace_transition_delivery = @import("workspace_transition_delivery.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const ActivationEffects = @import("ActivationEffects.zig");
const std = @import("std");
const ActivationCapture = @This();

model: *const ModelType,
activation: WorkspaceActivationType,
events: [4]workspace_transition_delivery.Event = undefined,
event_count: usize = 0,
committed_activation_observed: bool = true,
workspace: ?WorkspaceLocationType = null,
location: ?TabLocationType = null,
failure: workspace_transition_delivery.Failure = .none,

pub fn effects(capture: *ActivationCapture) ActivationEffects {
    return .{
        .context = capture,
        .synchronize_active_resources = synchronizeActiveResources,
        .schedule_host_input = scheduleHostInput,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.synchronize_active_resources);

    if (capture.failure == .synchronize_active_resources) {
        return error.ActiveResourceSyncFailed;
    }
}

fn scheduleHostInput(raw_context: *anyopaque) !void {
    const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.schedule_host_input);

    if (capture.failure == .schedule_host_input) {
        return error.HostInputScheduleFailed;
    }
}

fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_workspace_snapshot);
    capture.workspace = workspace;

    if (capture.failure == .request_workspace_snapshot) {
        return error.WorkspaceSnapshotRequestFailed;
    }
}

fn requestTabSnapshot(raw_context: *anyopaque, location: TabLocationType) !void {
    const capture: *ActivationCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_tab_snapshot);
    capture.location = location;

    if (capture.failure == .request_tab_snapshot) {
        return error.TabSnapshotRequestFailed;
    }
}

fn append(capture: *ActivationCapture, event: workspace_transition_delivery.Event) void {
    const version = capture.model.version();
    capture.committed_activation_observed = capture.committed_activation_observed and
        std.meta.eql(capture.model.activeTabLocation(), capture.activation.location) and
        version.workspace == capture.activation.workspace_revision and
        version.tabs == capture.activation.tabs_revision and
        version.active_tab == capture.activation.active_tab_revision and
        version.panes == capture.activation.panes_revision and
        version.copy == capture.activation.copy_revision;
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const ActivationCapture) []const workspace_transition_delivery.Event {
    return capture.events[0..capture.event_count];
}
