const view_interaction = @import("view_interaction.zig");
const IntentOutcome = @import("IntentOutcome.zig");
const Effects = @This();

context: *anyopaque,
apply_intent: *const fn (*anyopaque, view_interaction.Intent) anyerror!IntentOutcome,
invalidate_graphics_placements: *const fn (*anyopaque) void,
offer_pane_geometry: *const fn (*anyopaque) anyerror!void,
