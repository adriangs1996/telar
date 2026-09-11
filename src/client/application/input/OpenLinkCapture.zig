const Capture = @This();
const link_capability = @import("../../links/root.zig");
const Effects = @import("OpenLinkEffects.zig");
file: ?link_capability.FilePath = null,
external: ?link_capability.Target = null,

pub fn effects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .open_file = openFile,
        .open_external = openExternal,
    };
}

fn openFile(context: *anyopaque, path: link_capability.FilePath) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.file = path;
}

fn openExternal(context: *anyopaque, target: link_capability.Target) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.external = target;
}
