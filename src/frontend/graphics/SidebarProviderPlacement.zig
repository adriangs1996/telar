const RectType = @import("telar-core").Rect;
const kitty_sidebar = @import("kitty_sidebar.zig");
const SidebarProviderPlacement = @This();

area: RectType,
provider: kitty_sidebar.SidebarProvider,
