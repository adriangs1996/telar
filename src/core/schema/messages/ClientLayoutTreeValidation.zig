const types = @import("../types.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const std = @import("std");
const ClientLayoutTreeValidation = @This();

panes: [types.max_panes_per_tab]id.PaneId = undefined,
pane_count: usize = 0,
pending: usize = 1,

pub fn accept(self: *ClientLayoutTreeValidation, node: types.ClientLayoutNode) !void {
    if (self.pending == 0) {
        return error.InvalidClientLayoutTree;
    }

    self.pending -= 1;
    switch (node) {
        .pane => |pane| {
            try codec.validatePaneId(pane.id);
            if (std.mem.findScalar(id.PaneId, self.panes[0..self.pane_count], pane.id) != null) {
                return error.DuplicatePane;
            }
            if (self.pane_count == self.panes.len) {
                return error.TooManyPanes;
            }

            self.panes[self.pane_count] = pane.id;
            self.pane_count += 1;
        },
        .split => |split| {
            if (split.ratio < types.min_client_layout_ratio or split.ratio > types.max_client_layout_ratio) {
                return error.InvalidClientLayoutRatio;
            }

            self.pending += 2;
        },
    }
}

pub fn finish(self: *const ClientLayoutTreeValidation, layout: ClientLayoutTreeSummary) !void {
    if (self.pending != 0 or self.pane_count == 0 or layout.node_count != self.pane_count * 2 - 1) {
        return error.InvalidClientLayoutTree;
    }
    if (std.mem.findScalar(id.PaneId, self.panes[0..self.pane_count], layout.focused_pane) == null) {
        return error.InvalidClientLayoutFocus;
    }
}

const ClientLayoutTreeSummary = struct {
    node_count: usize,
    focused_pane: id.PaneId,
};
