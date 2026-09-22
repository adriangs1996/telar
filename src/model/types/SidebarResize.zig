const sidebar_module = @import("../layout/sidebar.zig");

pub const SidebarResize = union(enum) {
    exact: u16,
    direction: sidebar_module.Direction,
};
