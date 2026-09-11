const SidebarContent = @This();
const core = @import("telar-core");
const SidebarFocus = @import("SidebarFocus.zig");
const SidebarProviderPlacement = @import("SidebarProviderPlacement.zig");
area: core.ui.Rect,
focused_card: ?SidebarFocus,
provider_marks: []const SidebarProviderPlacement,
