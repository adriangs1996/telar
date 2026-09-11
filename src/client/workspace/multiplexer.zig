//! Pane membership, navigation and layout state independent of presentation.
const std = @import("std");
const core = @import("telar-core");
pub const schema = core.schema;
pub const ui = core.ui;
const client_panes = @import("../panes/root.zig");
pub const frame_apply = client_panes.frame;
const layout_mod = @import("layout_support.zig");
const input = @import("../input/root.zig");
pub const Pane = client_panes.Pane;
pub const max_panes = layout_mod.max_panes;
pub const PresentationCommit = client_panes.PresentationCommit;
pub const PaneIndex = core.fixed_index.SlotIndex(max_panes * 2);

pub const MetadataChange = enum {
    unchanged,
    stored,
    display_changed,
};

pub const PaneSpec = client_panes.Spec;

pub const PaneSplit = @import("PaneSplit.zig");

pub const DiscoveredPane = @import("DiscoveredPane.zig");

pub const PaneMousePlan = @import("PaneMousePlan.zig");

pub const Model = @import("MultiplexerModel.zig");

pub fn rectSize(rect: ui.Rect) ?schema.TerminalSize {
    if (rect.w == 0 or rect.h == 0) {
        return null;
    }
    return .{ .cols = rect.w, .rows = rect.h };
}

pub const placeholder_size: schema.TerminalSize = .{ .cols = 1, .rows = 1 };

pub const CopyProjection = @import("CopyProjection.zig");
