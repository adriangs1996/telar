const RectType = @import("telar-core").Rect;
const SidebarFocus = @import("SidebarFocus.zig");
const SidebarProviderPlacement = @import("SidebarProviderPlacement.zig");
const SidebarContent = @This();

area: RectType,
focused_card: ?SidebarFocus,
provider_marks: []const SidebarProviderPlacement,
