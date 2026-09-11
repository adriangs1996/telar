const SidebarLayout = @This();
const frontend_ui = @import("../layout/root.zig");
visible: bool,
width: u16 = frontend_ui.sidebar.default_width,
chrome_revision: u64,
