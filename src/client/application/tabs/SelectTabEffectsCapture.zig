const ModelType = @import("../../model/Model.zig");
const TabLocationType = @import("telar-core").TabLocation;
const SelectionEffects = @import("SelectionEffects.zig");
const TabSelectionType = @import("../../model/TabSelection.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
expected: TabLocationType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) SelectionEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, selection: TabSelectionType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const previous = capture.model.workspace.find(selection.previous.tab_id);
    const selected = capture.model.workspace.find(selection.selected.tab_id);
    const version = capture.model.version();
    capture.calls += 1;
    capture.observed_commit = std.meta.eql(capture.model.activeTabLocation(), capture.expected) and
        std.meta.eql(selection.selected, capture.expected) and
        previous != null and selected != null and
        previous.?.model.layout.currentRevision() == selection.previous_layout_revision and
        selected.?.model.layout.currentRevision() == selection.selected_layout_revision and
        version.workspace == selection.workspace_revision and
        version.tabs == selection.tabs_revision and
        version.active_tab == selection.active_tab_revision and
        version.panes == selection.panes_revision and
        version.copy == selection.copy_revision;
    if (capture.fail) {
        return error.SelectionSyncFailed;
    }
}
