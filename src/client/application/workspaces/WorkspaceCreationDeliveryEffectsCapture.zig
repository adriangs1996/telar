const ModelType = @import("../../model/Model.zig");
const WorkspaceReplacementType = @import("../../model/WorkspaceReplacement.zig");
const workspace_creation_delivery = @import("workspace_creation_delivery.zig");
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceBookmarkType = @import("../../model/WorkspaceBookmark.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const ReleaseEffectsType = @import("ReleaseEffects.zig");
const ActivationEffectsType = @import("ActivationEffects.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
replacement: *const WorkspaceReplacementType,
events: [12]workspace_creation_delivery.Event = undefined,
event_count: usize = 0,
cleared_panes: [4]PaneIdType = undefined,
cleared_count: usize = 0,
remembered: ?WorkspaceBookmarkType = null,
workspace_request: ?WorkspaceLocationType = null,
tab_request: ?TabLocationType = null,
exact_commit_observed: bool = true,
release_complete_before_activation: bool = false,
failure: workspace_creation_delivery.Failure = .none,

pub fn releaseEffects(capture: *EffectsCapture) ReleaseEffectsType {
    return .{
        .context = capture,
        .remember_bookmark = rememberBookmark,
        .clear_pane_graphics = clearPaneGraphics,
    };
}

pub fn activationEffects(capture: *EffectsCapture) ActivationEffectsType {
    return .{
        .context = capture,
        .synchronize_active_resources = synchronizeActiveResources,
        .schedule_host_input = scheduleHostInput,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn rememberBookmark(context: *anyopaque, bookmark: WorkspaceBookmarkType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.remember_bookmark);
    capture.remembered = bookmark;
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
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

fn requestWorkspaceSnapshot(context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.request_workspace_snapshot);
    capture.workspace_request = workspace;
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.request_tab_snapshot);
    capture.tab_request = location;
}

fn append(capture: *EffectsCapture, event: workspace_creation_delivery.Event) void {
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

pub fn eventSlice(capture: *const EffectsCapture) []const workspace_creation_delivery.Event {
    return capture.events[0..capture.event_count];
}
