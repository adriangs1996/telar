const Effects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
adopt_resources: *const fn (*anyopaque, client_model.ConfigurationCommit) void,
synchronize_bars: *const fn (*anyopaque) anyerror!void,
project_appearance: *const fn (*anyopaque, bool) void,
configure_sidebar: *const fn (*anyopaque) anyerror!void,
apply_sidebar: *const fn (*anyopaque, client_model.SidebarLayout) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_active_pane_geometry: *const fn (*anyopaque) anyerror!void,
