const Route = @import("Route.zig");
const PasteRoutingEffects = @import("PasteRoutingEffects.zig");
const Capture = @This();

route_value: ?Route = null,
calls: usize = 0,
fail: bool = false,

pub fn effects(capture: *Capture) PasteRoutingEffects {
    return .{ .context = capture, .route = route };
}

fn route(raw_context: *anyopaque, value: Route) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.route_value = value;

    if (capture.fail) {
        return error.PasteRouteFailed;
    }
}
