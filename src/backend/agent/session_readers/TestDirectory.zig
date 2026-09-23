const core = @import("telar-core");
const std = @import("std");
const Watch = @import("../Watch.zig");
const SessionReference = @import("../SessionReference.zig");
const TestDirectory = @This();

temp: std.testing.TmpDir,
buffer: [std.fs.max_path_bytes]u8 = undefined,
len: usize = 0,

pub fn init(io: std.Io) !TestDirectory {
    var directory: TestDirectory = .{ .temp = std.testing.tmpDir(.{}) };
    directory.len = try directory.temp.dir.realPath(io, &directory.buffer);
    return directory;
}

pub fn deinit(self: *TestDirectory) void {
    self.temp.cleanup();
}

pub fn watch(self: *const TestDirectory, kind: core.AgentSessionFileKind, name: []const u8) !Watch {
    var value: Watch = .{
        .key = .{ .id = try core.pane(7), .generation = 3 },
        .session = try SessionReference.init("abc", 1),
        .kind = kind,
    };
    const path = try std.fmt.bufPrint(&value.path, "{s}/{s}", .{ self.buffer[0..self.len], name });
    value.path_len = @intCast(path.len);
    return value;
}
