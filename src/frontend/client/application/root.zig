//! Client application use cases.

pub const create_tab = @import("create_tab.zig");
pub const select_tab = @import("select_tab.zig");

test {
    _ = create_tab;
    _ = select_tab;
}
