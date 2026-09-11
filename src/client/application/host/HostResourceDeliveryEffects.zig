const SidebarConfiguration = @import("SidebarConfiguration.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const types = @import("../../model/types.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;
const Effects = @This();

context: *anyopaque,
sync_graphics_fallbacks: *const fn (*anyopaque) void,
configure_sidebar: *const fn (*anyopaque, SidebarConfiguration) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
resize_presenter: *const fn (*anyopaque, TerminalSizeType) anyerror!void,
resize_view: *const fn (*anyopaque, TerminalSizeType) anyerror!void,
sync_pane_geometry: *const fn (*anyopaque) anyerror!void,
apply_appearance: *const fn (*anyopaque, types.HostAppearance) anyerror!void,
sync_terminal_colors: *const fn (*anyopaque, TerminalColorsType) anyerror!void,
