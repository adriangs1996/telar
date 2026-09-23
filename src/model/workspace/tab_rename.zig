//! A tab takes a canonical label (docs/flows/tab-rename.md).
const core = @import("telar-core");
const std = @import("std");
const Model = @import("../state/Model.zig");
const Change = @import("../types/Change.zig").Change;
const label_validation = @import("label_validation.zig");

/// Stores one validated canonical label and reports whether it changed.
/// Example: `const change = try tab_rename.rename(model, tab_id, "server");`
pub fn rename(model: *Model, tab_id: core.TabId, label: []const u8) !Change {
    const slot = model.tabs.find(tab_id) orelse return error.TabNotFound;
    try label_validation.validate(label, .renamed_tab);

    if (std.mem.eql(u8, model.tabs.canonicalLabel(slot), label)) {
        return .unchanged;
    }

    model.tabs.setLabel(slot, label);
    return .changed;
}
