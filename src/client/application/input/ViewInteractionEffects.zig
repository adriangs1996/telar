const Effects = @This();
const source_namespace = @import("view_interaction.zig");
const IntentOutcome = @import("IntentOutcome.zig");
context: *anyopaque,
apply_intent: *const fn (*anyopaque, source_namespace.Intent) anyerror!IntentOutcome,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque) anyerror!void,
