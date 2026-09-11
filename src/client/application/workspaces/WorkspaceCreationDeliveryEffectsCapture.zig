const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_creation_delivery.zig");
const workspace_transition_delivery = @import("workspace_transition_delivery.zig");
const std = @import("std");
model: *client_model.Model,
replacement: *const client_model.WorkspaceReplacement,
events: [12]source_namespace.Event = undefined,
event_count: usize = 0,
cleared_panes: [4]source_namespace.schema.PaneId = undefined,
cleared_count: usize = 0,
remembered: ?client_model.WorkspaceBookmark = null,
workspace_request: ?source_namespace.schema.WorkspaceLocation = null,
tab_request: ?source_namespace.schema.TabLocation = null,
exact_commit_observed: bool = true,
release_complete_before_activation: bool = false,
failure: source_namespace.Failure = .none,

pub fn releaseEffects(capture: *EffectsCapture) workspace_transition_delivery.ReleaseEffects {
    return .{
        .context = capture,
        .remember_bookmark = rememberBookmark,
        .clear_pane_graphics = clearPaneGraphics,
    };
}

pub fn activationEffects(capture: *EffectsCapture) workspace_transition_delivery.ActivationEffects {
    return .{
        .context = capture,
        .synchronize_active_resources = synchronizeActiveResources,
        .schedule_host_input = scheduleHostInput,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn rememberBookmark(context: *anyopaque, bookmark: client_model.WorkspaceBookmark) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.remember_bookmark);
    capture.remembered = bookmark;
}

fn clearPaneGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.clear_pane_graphics);
    capture.cleared_panes[capture.cleared_count] = pane_id;
    capture.cleared_count += 1;
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_active_resources);
    capture.release_complete_before_activation =
        capture.cleared_count == capture.replacement.departure.panes.slice().len and
        !capture.model.panePasteActive() and
        capture.model.reportedPaneFocus() == null;

    if (capture.failure == .active_resources) {
        return error.ActiveResourcesFailed;
    }
}

fn scheduleHostInput(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.schedule_host_input);
}

fn requestWorkspaceSnapshot(context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.request_workspace_snapshot);
    capture.workspace_request = workspace;
}

fn requestTabSnapshot(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.request_tab_snapshot);
    capture.tab_request = location;
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
    capture.exact_commit_observed = capture.exact_commit_observed and capture.observesCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observesCommit(capture: *const EffectsCapture) bool {
    const activation = capture.replacement.activation;
    const version = capture.model.version();

    return std.meta.eql(capture.model.activeTabLocation(), activation.location) and
        version.workspace == activation.workspace_revision and
        version.tabs == activation.tabs_revision and
        version.active_tab == activation.active_tab_revision and
        version.panes == activation.panes_revision and
        version.copy == activation.copy_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
