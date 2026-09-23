const std = @import("std");
const config_reload = @import("config_reload.zig");
const data = @import("model");
const ResolveArgs = @This();

gpa: std.mem.Allocator,
reload: config_reload.ConfigReload,
checks: Checks,

const Checks = struct {
    /// The client facts `resolve` validates a loaded configuration against.
    kitty_support: data.EnvironmentSupport,
    sidebar_renderer_locked: bool,
    current_sidebar: data.SidebarRendering,
};
