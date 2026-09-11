const TestDirectory = @This();
const std = @import("std");
const source_namespace = @import("root.zig");
const session_file = @import("../session_file.zig");
temp: std.testing.TmpDir,
buffer: [std.fs.max_path_bytes]u8 = undefined,
len: usize = 0,

pub fn init(io: source_namespace.Io) !TestDirectory {
    var directory: TestDirectory = .{ .temp = std.testing.tmpDir(.{}) };
    directory.len = try directory.temp.dir.realPath(io, &directory.buffer);
    return directory;
}

pub fn deinit(directory: *TestDirectory) void {
    directory.temp.cleanup();
}

pub fn watch(directory: *const TestDirectory, kind: session_file.Kind, name: []const u8) !session_file.Watch {
    var value: session_file.Watch = .{
        .key = .{ .id = try source_namespace.schema.id.pane(7), .generation = 3 },
        .session = try @import("../types.zig").SessionReference.init("abc", 1),
        .kind = kind,
    };
    const path = try std.fmt.bufPrint(&value.path, "{s}/{s}", .{ directory.buffer[0..directory.len], name });
    value.path_len = @intCast(path.len);
    return value;
}
