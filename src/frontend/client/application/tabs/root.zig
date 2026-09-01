//! Tab lifecycle and synchronization flows owned by the client application.

pub const close_tab = @import("close_tab.zig");
pub const create_tab = @import("create_tab.zig");
pub const move_tab = @import("move_tab.zig");
pub const rename_tab = @import("rename_tab.zig");
pub const select_tab = @import("select_tab.zig");
pub const tab_attachment_retirement = @import("tab_attachment_retirement.zig");
pub const tab_close_preparation = @import("tab_close_preparation.zig");
pub const tab_creation_delivery = @import("tab_creation_delivery.zig");
pub const tab_removal_delivery = @import("tab_removal_delivery.zig");
pub const tab_selection_delivery = @import("tab_selection_delivery.zig");
pub const tab_snapshot = @import("tab_snapshot.zig");
pub const tab_snapshot_delivery = @import("tab_snapshot_delivery.zig");
pub const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");

test {
    _ = close_tab;
    _ = create_tab;
    _ = move_tab;
    _ = rename_tab;
    _ = select_tab;
    _ = tab_attachment_retirement;
    _ = tab_close_preparation;
    _ = tab_creation_delivery;
    _ = tab_removal_delivery;
    _ = tab_selection_delivery;
    _ = tab_snapshot;
    _ = tab_snapshot_delivery;
    _ = tab_snapshot_recovery;
}
