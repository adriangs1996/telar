const ProxyTestFiles = @This();
const std = @import("std");
const source_namespace = @import("proxy.zig");
temp: std.testing.TmpDir,
key: [std.fs.max_path_bytes]u8 = undefined,
key_len: usize = 0,
certificate: [std.fs.max_path_bytes]u8 = undefined,
certificate_len: usize = 0,
bundle: [std.fs.max_path_bytes]u8 = undefined,
bundle_len: usize = 0,

pub fn init(io: source_namespace.Io) !ProxyTestFiles {
    var files: ProxyTestFiles = .{ .temp = std.testing.tmpDir(.{}) };
    errdefer files.temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try files.temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    files.key_len = (try std.fmt.bufPrint(&files.key, "{s}/ca-key.pem", .{directory})).len;
    files.certificate_len = (try std.fmt.bufPrint(&files.certificate, "{s}/ca-cert.pem", .{directory})).len;
    files.bundle_len = (try std.fmt.bufPrint(&files.bundle, "{s}/ca-bundle.pem", .{directory})).len;

    return files;
}

pub fn deinit(files: *ProxyTestFiles) void {
    files.temp.cleanup();
}

pub fn config(files: *const ProxyTestFiles) source_namespace.Config {
    return .{
        .key_path = files.key[0..files.key_len],
        .certificate_path = files.certificate[0..files.certificate_len],
        .bundle_path = files.bundle[0..files.bundle_len],
    };
}
