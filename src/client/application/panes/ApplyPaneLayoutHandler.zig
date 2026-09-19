const Model = @import("../../model/Model.zig");
const PaneLayoutRequest = @import("../../model/PaneLayoutRequest.zig");
const FocusEffects = @import("FocusEffects.zig");
const Handler = @This();
model: *Model,
effects: FocusEffects,

/// Commits membership-checked layout before shared focus/geometry delivery. Example: `try handler.execute(request);`
pub fn execute(self: *Handler, request: PaneLayoutRequest) !void {
    const change = try self.model.applyPaneLayout(request);
    try self.effects.deliver(self.effects.context, change, request.area);
}
