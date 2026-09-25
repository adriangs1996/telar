//! A tab takes a canonical label (docs/flows/tab-rename.md).
const RenameTab = @import("../state/RenameTab.zig");
const tab_rename = @import("tab_rename.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const Change = @import("../state/Change.zig").Change;
const label_validation = @import("label_validation.zig");

/// Stores one validated canonical label and reports whether it changed.
/// Example: `const change = try tab_rename.rename(model, tab_id, "server");`
pub fn rename(model: *ClientModel, tab_id: core.TabId, label: []const u8) !Change {
    const slot = model.tabs.find(tab_id) orelse return error.TabNotFound;
    try label_validation.validate(label, .renamed_tab);

    if (std.mem.eql(u8, model.tabs.canonicalLabel(slot), label)) {
        return .unchanged;
    }

    model.tabs.setLabel(slot, label);
    return .changed;
}

/// Commits a runtime-confirmed label and advances the tab collection once.
///
/// ```zig
/// const change = try tab_rename.commitRename(model, command);
/// ```
pub fn commitRename(model: *ClientModel, command: RenameTab) !model_data.Change {
    const current_workspace = model.workspace orelse return error.UnexpectedWorkspace;
    if (!std.meta.eql(current_workspace, command.location.workspace)) {
        return error.UnexpectedWorkspace;
    }

    const change = try tab_rename.rename(model, command.location.tab_id, command.label);
    if (change == .unchanged) {
        return .unchanged;
    }

    model.tabs_revision +%= 1;
    return .changed;
}
