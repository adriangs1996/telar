const Effects = @This();
const SidebarConfiguration = @import("SidebarConfiguration.zig");
const source_namespace = @import("host_resource_delivery.zig");
const client_model = @import("../../root.zig").model;
context: *anyopaque,
sync_graphics_fallbacks: *const fn (*anyopaque) void,
configure_sidebar: *const fn (*anyopaque, SidebarConfiguration) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
resize_presenter: *const fn (*anyopaque, source_namespace.schema.TerminalSize) anyerror!void,
resize_view: *const fn (*anyopaque, source_namespace.schema.TerminalSize) anyerror!void,
sync_pane_geometry: *const fn (*anyopaque) anyerror!void,
apply_appearance: *const fn (*anyopaque, client_model.HostAppearance) anyerror!void,
sync_terminal_colors: *const fn (*anyopaque, source_namespace.schema.TerminalColors) anyerror!void,
