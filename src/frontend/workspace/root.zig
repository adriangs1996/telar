//! Disposable workspace layout and pane composition.

pub const layout = @import("layout.zig");
pub const multiplexer = @import("multiplexer.zig");
pub const navigation = @import("navigation.zig");
pub const tabs = @import("tabs.zig");
pub const workspace_list = @import("workspace_list.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
