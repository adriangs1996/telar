//! Pane membership, navigation and layout state independent of presentation.

const core = @import("telar-core");

pub const PaneIndex = core.GenericSlotIndex(core.max_panes_per_tab * 2);

pub const MetadataChange = enum {
    unchanged,
    stored,
    display_changed,
};

pub fn rectSize(rect: core.Rect) ?core.TerminalSize {
    if (rect.w == 0 or rect.h == 0) {
        return null;
    }
    return .{ .cols = rect.w, .rows = rect.h };
}

pub const placeholder_size: core.TerminalSize = .{ .cols = 1, .rows = 1 };
