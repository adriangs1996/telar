const std = @import("std");
const Service = @import("Service.zig");
const TestServiceFixture = @This();

temp: std.testing.TmpDir = undefined,
key: [std.fs.max_path_bytes]u8 = undefined,
certificate: [std.fs.max_path_bytes]u8 = undefined,
bundle: [std.fs.max_path_bytes]u8 = undefined,
service: ?*Service = null,

pub fn init(self: *TestServiceFixture, io: std.Io, gpa: std.mem.Allocator) !void {
    self.temp = std.testing.tmpDir(.{});
    errdefer self.temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try self.temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    self.service = try Service.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&self.key, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&self.certificate, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&self.bundle, "{s}/ca-bundle.pem", .{directory}),
    });
}

pub fn deinit(self: *TestServiceFixture) void {
    self.service.?.destroy();
    self.temp.cleanup();
}
