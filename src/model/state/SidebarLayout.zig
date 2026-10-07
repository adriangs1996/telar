const sidebar_module = @import("../layout/sidebar.zig");

visible: bool,
width: u16 = sidebar_module.default_width,
chrome_revision: u64,
