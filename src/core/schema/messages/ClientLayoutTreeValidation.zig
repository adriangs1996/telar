const types = @import("../types.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const std = @import("std");
const ClientLayoutTreeSummary = @import("ClientLayoutTreeSummary.zig");
const ClientLayoutTreeValidation = @This();

panes: [types.max_panes_per_tab]id.PaneId = undefined,
pane_count: usize = 0,
pending: usize = 1,

pub fn accept(validation: *ClientLayoutTreeValidation, node: types.ClientLayoutNode) !void {
    if (validation.pending == 0) {
        return error.InvalidClientLayoutTree;
    }

    validation.pending -= 1;
    switch (node) {
        .pane => |pane| {
            try codec.validatePaneId(pane.id);
            if (std.mem.findScalar(id.PaneId, validation.panes[0..validation.pane_count], pane.id) != null) {
                return error.DuplicatePane;
            }
            if (validation.pane_count == validation.panes.len) {
                return error.TooManyPanes;
            }

            validation.panes[validation.pane_count] = pane.id;
            validation.pane_count += 1;
        },
        .split => |split| {
            if (split.ratio < types.min_client_layout_ratio or split.ratio > types.max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            validation.pending += 2;
        },
    }
}

pub fn finish(validation: *const ClientLayoutTreeValidation, layout: ClientLayoutTreeSummary) !void {
    if (validation.pending != 0 or validation.pane_count == 0 or layout.node_count != validation.pane_count * 2 - 1) {
        return error.InvalidClientLayoutTree;
    }
    if (std.mem.findScalar(id.PaneId, validation.panes[0..validation.pane_count], layout.focused_pane) == null) {
        return error.InvalidClientLayoutFocus;
    }
}
