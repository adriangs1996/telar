const cellgrid = @import("cellgrid");
const kitty_sidebar = @import("kitty_sidebar.zig");
const SidebarProviderPlacement = @This();

area: cellgrid.Rect,
provider: kitty_sidebar.SidebarProvider,
