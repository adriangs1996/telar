const SupportType = @import("telar-client").Support;
const capabilities = @import("../../graphics/capabilities.zig");
/// The client facts `resolve` validates a loaded configuration against.
const Checks = @This();

kitty_support: SupportType,
sidebar_renderer_locked: bool,
current_sidebar: capabilities.SidebarRendering,
