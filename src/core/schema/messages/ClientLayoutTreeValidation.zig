const ClientLayoutTreeValidation = @This();
const source_namespace = @import("layout.zig");
const std = @import("std");
const ClientLayoutTreeSummary = @import("ClientLayoutTreeSummary.zig");
panes: [source_namespace.max_panes_per_tab]source_namespace.PaneId = undefined,
pane_count: usize = 0,
pending: usize = 1,

pub fn accept(validation: *ClientLayoutTreeValidation, node: source_namespace.ClientLayoutNode) !void {
    if (validation.pending == 0) {
        return error.InvalidClientLayoutTree;
    }

    validation.pending -= 1;
    switch (node) {
        .pane => |pane_id| {
            try source_namespace.validatePaneId(pane_id);
            if (std.mem.findScalar(source_namespace.PaneId, validation.panes[0..validation.pane_count], pane_id) != null) {
                return error.DuplicatePane;
            }
            if (validation.pane_count == validation.panes.len) {
                return error.TooManyPanes;
            }

            validation.panes[validation.pane_count] = pane_id;
            validation.pane_count += 1;
        },
        .split => |split| {
            if (split.ratio < source_namespace.min_client_layout_ratio or split.ratio > source_namespace.max_client_layout_ratio) {
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
    if (std.mem.findScalar(source_namespace.PaneId, validation.panes[0..validation.pane_count], layout.focused_pane) == null) {
        return error.InvalidClientLayoutFocus;
    }
}
