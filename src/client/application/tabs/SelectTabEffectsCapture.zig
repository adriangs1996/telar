const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("select_tab.zig");
const SelectionEffects = @import("SelectionEffects.zig");
const std = @import("std");
model: *client_model.Model,
expected: source_namespace.schema.TabLocation,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *EffectsCapture) SelectionEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, selection: client_model.TabSelection) !void {
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
