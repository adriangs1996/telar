//! A tab takes a new position in its workspace (docs/flows/tab-move.md).
const std = @import("std");
const tab_move = @import("tab_move.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
const Change = @import("../state/Change.zig").Change;

/// Applies a canonical runtime position while keeping the active tab.
/// Example: `const change = try tab_move.move(model, tab_id, 1);`
pub fn move(model: *ClientModel, tab_id: core.TabId, position: u16) !Change {
    const from = model.tabs.find(tab_id) orelse return error.TabNotFound;
    const target: usize = position;
    if (target >= model.tabs.count) {
        return error.InvalidTabPosition;
    }

    if (from == target) {
        return .unchanged;
    }

    const active_id = model.tabs.location[model.tabs.active].tab_id;
    model.tabs.move(from, target);
    model.tabs.active = model.tabs.find(active_id).?;
    return .changed;
}

/// Commits a runtime-confirmed tab position and advances the model once.
///
/// ```zig
/// const change = try tab_move.applyPosition(model, location, position);
/// ```
pub fn applyPosition(model: *ClientModel, location: core.TabLocation, position: u16) !model_data.Change {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, location.workspace)) {
        return error.UnexpectedWorkspace;
    }

    const change = try tab_move.move(model, location.tab_id, position);
    if (change == .unchanged) {
        return .unchanged;
    }

    model.tabs_revision +%= 1;
    return .changed;
}
