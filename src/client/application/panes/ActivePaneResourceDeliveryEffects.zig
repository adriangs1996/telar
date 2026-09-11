const Effects = @This();
const attachments = @import("../../attachments/root.zig");
const source_namespace = @import("active_pane_resource_delivery.zig");
const agents = @import("../../root.zig").agents;
context: *anyopaque,
sync_attachment_target: *const fn (*anyopaque, ?attachments.Target) ?source_namespace.ui.Rect,
sync_focus_reporting: *const fn (*anyopaque) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque, source_namespace.ui.Rect) anyerror!void,
request_visible_attachments: *const fn (*anyopaque, source_namespace.ui.Rect) anyerror!void,
acknowledge_agent: *const fn (*anyopaque, agents.AgentKey) anyerror!void,
