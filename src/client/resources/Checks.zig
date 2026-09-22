const data = @import("model");
const sidebar_rendering = @import("../config/sidebar_rendering.zig");
/// The client facts `resolve` validates a loaded configuration against.
const Checks = @This();

kitty_support: data.EnvironmentSupport,
sidebar_renderer_locked: bool,
current_sidebar: sidebar_rendering.SidebarRendering,
