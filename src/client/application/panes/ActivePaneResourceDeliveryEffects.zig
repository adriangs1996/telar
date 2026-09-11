const TargetType = @import("../../attachments/AttachmentTarget.zig");
const RectType = @import("telar-core").Rect;
const AgentKeyType = @import("../../agents/AgentKey.zig");
const Effects = @This();

context: *anyopaque,
sync_attachment_target: *const fn (*anyopaque, ?TargetType) ?RectType,
sync_focus_reporting: *const fn (*anyopaque) anyerror!void,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque, RectType) anyerror!void,
request_visible_attachments: *const fn (*anyopaque, RectType) anyerror!void,
acknowledge_agent: *const fn (*anyopaque, AgentKeyType) anyerror!void,
