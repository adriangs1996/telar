//! Disposable workspace layout and pane composition.

pub const layout = @import("telar-client").workspace.layout;
pub const multiplexer = @import("multiplexer.zig");
pub const navigation = @import("telar-client").workspace.navigation;
pub const tabs = @import("telar-client").workspace.tabs;
pub const workspace_list = @import("telar-client").workspace.workspace_list;

test {
    @import("std").testing.refAllDecls(@This());
}
