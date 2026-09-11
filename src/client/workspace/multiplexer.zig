//! Pane membership, navigation and layout state independent of presentation.

const GenericSlotIndex = @import("telar-core").GenericSlotIndex;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const RectType = @import("telar-core").Rect;
const TerminalSizeType = @import("telar-core").TerminalSize;

pub const PaneIndex = GenericSlotIndex(max_panes_per_tab * 2);

pub const MetadataChange = enum {
    unchanged,
    stored,
    display_changed,
};

pub fn rectSize(rect: RectType) ?TerminalSizeType {
    if (rect.w == 0 or rect.h == 0) {
        return null;
    }
    return .{ .cols = rect.w, .rows = rect.h };
}

pub const placeholder_size: TerminalSizeType = .{ .cols = 1, .rows = 1 };
