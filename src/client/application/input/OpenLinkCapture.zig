const FilePathType = @import("../../links/FilePath.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const OpenLinkEffects = @import("OpenLinkEffects.zig");
const Capture = @This();

file: ?FilePathType = null,
external: ?TargetType = null,

pub fn effects(capture: *Capture) OpenLinkEffects {
    return .{
        .context = capture,
        .open_file = openFile,
        .open_external = openExternal,
    };
}

fn openFile(context: *anyopaque, path: FilePathType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.file = path;
}

fn openExternal(context: *anyopaque, target: TargetType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.external = target;
}
