const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const Effects = @This();

context: *anyopaque,
adopt_resources: *const fn (*anyopaque, ConfigurationCommitType) void,
synchronize_bars: *const fn (*anyopaque) anyerror!void,
project_appearance: *const fn (*anyopaque, bool) void,
configure_sidebar: *const fn (*anyopaque) anyerror!void,
apply_sidebar: *const fn (*anyopaque, SidebarLayoutType) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_active_pane_geometry: *const fn (*anyopaque) anyerror!void,
