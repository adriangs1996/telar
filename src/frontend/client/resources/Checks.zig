/// The client facts `resolve` validates a loaded configuration against.
const Checks = @This();
const source_namespace = @import("config_reload.zig");
kitty_support: source_namespace.kitty.Support,
sidebar_renderer_locked: bool,
current_sidebar: source_namespace.kitty.SidebarRendering,
