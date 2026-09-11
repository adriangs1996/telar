const Capture = @This();
const source_namespace = @import("client_detachment.zig");
const Effects = @import("ClientDetachmentEffects.zig");
locations: [source_namespace.schema.max_tabs_per_workspace]source_namespace.schema.TabLocation = undefined,
location_count: usize = 0,
fail_at: ?usize = null,

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .detach_tab = detachTab };
}

fn detachTab(raw_context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.locations[capture.location_count] = location;
    capture.location_count += 1;

    if (capture.fail_at == capture.location_count) {
        return error.DetachmentFailed;
    }
}

pub fn slice(capture: *const Capture) []const source_namespace.schema.TabLocation {
    return capture.locations[0..capture.location_count];
}
