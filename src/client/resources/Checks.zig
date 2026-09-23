const data = @import("model");
/// The client facts `resolve` validates a loaded configuration against.
const Checks = @This();

kitty_support: data.EnvironmentSupport,
sidebar_renderer_locked: bool,
current_sidebar: data.SidebarRendering,
