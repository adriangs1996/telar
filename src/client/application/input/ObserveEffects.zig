const ObserveEffects = @This();
const attachments = @import("../../attachments/root.zig");
context: *anyopaque,
visible_target: *const fn (*anyopaque) ?attachments.Target,
marker_at_cursor: *const fn (*anyopaque, attachments.MarkerDeletion) ?attachments.Id,
pending_marker_at_cursor: *const fn (*anyopaque, attachments.MarkerDeletion) bool,
prompt_continues: *const fn (*anyopaque, attachments.Target) bool,
remove: *const fn (*anyopaque, attachments.Id) ?bool,
remove_prompt: *const fn (*anyopaque, attachments.Target) ?bool,
