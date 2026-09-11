const TargetType = @import("../../attachments/AttachmentTarget.zig");
const types = @import("../../attachments/types.zig");
const ObserveEffects = @This();

context: *anyopaque,
visible_target: *const fn (*anyopaque) ?TargetType,
marker_at_cursor: *const fn (*anyopaque, types.MarkerDeletion) ?types.Id,
pending_marker_at_cursor: *const fn (*anyopaque, types.MarkerDeletion) bool,
prompt_continues: *const fn (*anyopaque, TargetType) bool,
remove: *const fn (*anyopaque, types.Id) ?bool,
remove_prompt: *const fn (*anyopaque, TargetType) ?bool,
