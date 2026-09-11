//! TLS interception resources owned for the lifetime of one proxy service.

const std = @import("std");
const Interception = @import("Interception.zig");
const CountersType = @import("../Counters.zig");

test "interception owns trust paths and exposes bounded tunnel resources" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var certificate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory});
    const certificate_path = try std.fmt.bufPrint(&certificate_buffer, "{s}/ca-cert.pem", .{directory});
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory});

    var interception = try Interception.init(io, gpa, .{
        .key = key_path,
        .certificate = certificate_path,
        .bundle = bundle_path,
        .intercept_hosts = &.{"localhost"},
    });
    defer interception.deinit();
    const trust = interception.clientTrust();
    var telemetry: CountersType = .{};
    const resources = interception.tunnelResources(&telemetry);

    try std.testing.expectEqualStrings(certificate_path, trust.certificate_path);
    try std.testing.expectEqualStrings(bundle_path, trust.bundle_path);
    try std.testing.expect(resources.authority == &interception.authority);
    try std.testing.expect(resources.roots == &interception.roots);
    try std.testing.expect(resources.telemetry == &telemetry);
    try std.testing.expect(resources.intercept_hosts.contains("localhost"));
    try std.testing.expect(!resources.intercept_hosts.contains("api.openai.com"));
}
