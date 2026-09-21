//! Application use case for toggling one client's sidebar preference.

const sidebar_module = @import("../../layout/sidebar.zig");
const std = @import("std");

pub const Resize = union(enum) {
    exact: u16,
    direction: sidebar_module.Direction,
};
