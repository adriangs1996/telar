const SupportType = @import("../environment/environment.zig").Support;
const SidebarRenderingType = @import("../config/sidebar_rendering.zig").SidebarRendering;
/// The client facts `resolve` validates a loaded configuration against.
const Checks = @This();

kitty_support: SupportType,
sidebar_renderer_locked: bool,
current_sidebar: SidebarRenderingType,
