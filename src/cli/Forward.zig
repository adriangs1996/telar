/// One live SSH socket forward. Stopping it kills the ssh child and removes
/// the local socket file.
const Forward = @This();
const std = @import("std");
const Discovery = @import("remote_discovery.zig").Discovery;
const source_namespace = @import("remote.zig");
child: std.process.Child,
discovery: Discovery,
local_path: [std.fs.max_path_bytes:0]u8 = undefined,
local_path_len: usize = 0,

pub fn localPath(self: *const Forward) []const u8 {
    return self.local_path[0..self.local_path_len];
}

pub fn localPathZ(self: *Forward) [*:0]const u8 {
    self.local_path[self.local_path_len] = 0;
    return self.local_path[0..self.local_path_len :0];
}

pub fn stop(self: *Forward, io: source_namespace.Io) void {
    self.child.kill(io);
    source_namespace.Io.Dir.deleteFileAbsolute(io, self.localPath()) catch {};
}
