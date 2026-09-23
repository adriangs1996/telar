//! A new pane splits an existing one (docs/flows/pane-split.md).
const std = @import("std");
const Model = @import("../state/Model.zig");
const PaneSplit = @import("PaneSplit.zig");
const multiplexer = @import("multiplexer.zig");
const tab_layout = @import("tab_layout.zig");

/// Adds `request.new_pane` beside `request.existing_pane` in tab `slot`.
/// Example: `try pane_split.split(model, slot, request);`
pub fn split(model: *Model, slot: usize, request: PaneSplit) !void {
    const prospective = tab_layout.prospectiveSplit(
        model,
        slot,
        .{
            .pane_id = request.existing_pane,
            .axis = request.axis,
        },
        request.area,
    ) orelse return error.PaneTooSmall;
    const size = multiplexer.rectSize(prospective.new_content) orelse return error.PaneTooSmall;

    _ = try model.panes.add(
        model.gpa,
        .{
            .pane_id = request.new_pane,
            .location = request.location,
            .size = size,
        },
        true,
    );
    errdefer _ = model.panes.remove(request.new_pane);
    try model.tabs.layout[slot].split(.{
        .existing_pane = request.existing_pane,
        .new_pane = request.new_pane,
        .axis = request.axis,
    });
}

test {
    std.testing.refAllDecls(@This());
}
