const core = @import("telar-core");
const kitty_sidebar = @import("kitty_sidebar.zig");
const SidebarProviderPlacement = @This();

area: core.Rect,
provider: kitty_sidebar.SidebarProvider,
