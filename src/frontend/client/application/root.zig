//! Client application use cases.

pub const close_tab = @import("close_tab.zig");
pub const create_tab = @import("create_tab.zig");
pub const select_tab = @import("select_tab.zig");

test {
    _ = close_tab;
    _ = create_tab;
    _ = select_tab;
}
