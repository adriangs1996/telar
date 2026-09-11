const std = @import("std");
const AgentSessionFileKind = @import("telar-core").AgentSessionFileKind;
const WatchType = @import("../Watch.zig");
const pane_module = @import("telar-core").pane;
const SessionReferenceType = @import("../SessionReference.zig");
const TestDirectory = @This();

temp: std.testing.TmpDir,
buffer: [std.fs.max_path_bytes]u8 = undefined,
len: usize = 0,

pub fn init(io: std.Io) !TestDirectory {
    var directory: TestDirectory = .{ .temp = std.testing.tmpDir(.{}) };
    directory.len = try directory.temp.dir.realPath(io, &directory.buffer);
    return directory;
}

pub fn deinit(directory: *TestDirectory) void {
    directory.temp.cleanup();
}

pub fn watch(directory: *const TestDirectory, kind: AgentSessionFileKind, name: []const u8) !WatchType {
    var value: WatchType = .{
        .key = .{ .id = try pane_module(7), .generation = 3 },
        .session = try SessionReferenceType.init("abc", 1),
        .kind = kind,
    };
    const path = try std.fmt.bufPrint(&value.path, "{s}/{s}", .{ directory.buffer[0..directory.len], name });
    value.path_len = @intCast(path.len);
    return value;
}
