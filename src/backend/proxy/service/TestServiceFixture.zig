const std = @import("std");
const ServiceType = @import("Service.zig");
const TestServiceFixture = @This();

temp: std.testing.TmpDir = undefined,
key: [std.fs.max_path_bytes]u8 = undefined,
certificate: [std.fs.max_path_bytes]u8 = undefined,
bundle: [std.fs.max_path_bytes]u8 = undefined,
service: ?*ServiceType = null,

pub fn init(fixture: *TestServiceFixture, io: std.Io, gpa: std.mem.Allocator) !void {
    fixture.temp = std.testing.tmpDir(.{});
    errdefer fixture.temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try fixture.temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    fixture.service = try ServiceType.create(io, gpa, .{
        .key = try std.fmt.bufPrint(&fixture.key, "{s}/ca-key.pem", .{directory}),
        .certificate = try std.fmt.bufPrint(&fixture.certificate, "{s}/ca-cert.pem", .{directory}),
        .bundle = try std.fmt.bufPrint(&fixture.bundle, "{s}/ca-bundle.pem", .{directory}),
    });
}

pub fn deinit(fixture: *TestServiceFixture) void {
    fixture.service.?.destroy();
    fixture.temp.cleanup();
}
