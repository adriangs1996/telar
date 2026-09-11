const max_tabs_per_workspace_module = @import("telar-core").max_tabs_per_workspace;
const TabLocationType = @import("telar-core").TabLocation;
const ClientDetachmentEffects = @import("ClientDetachmentEffects.zig");
const Capture = @This();

locations: [max_tabs_per_workspace_module]TabLocationType = undefined,
location_count: usize = 0,
fail_at: ?usize = null,

pub fn effects(capture: *Capture) ClientDetachmentEffects {
    return .{ .context = capture, .detach_tab = detachTab };
}

fn detachTab(raw_context: *anyopaque, location: TabLocationType) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.locations[capture.location_count] = location;
    capture.location_count += 1;

    if (capture.fail_at == capture.location_count) {
        return error.DetachmentFailed;
    }
}

pub fn slice(capture: *const Capture) []const TabLocationType {
    return capture.locations[0..capture.location_count];
}
