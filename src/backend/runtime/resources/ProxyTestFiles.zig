const std = @import("std");
const Config = @import("../../proxy/Config.zig");
const ProxyTestFiles = @This();

temp: std.testing.TmpDir,
key: [std.fs.max_path_bytes]u8 = undefined,
key_len: usize = 0,
certificate: [std.fs.max_path_bytes]u8 = undefined,
certificate_len: usize = 0,
bundle: [std.fs.max_path_bytes]u8 = undefined,
bundle_len: usize = 0,
secret: [std.fs.max_path_bytes]u8 = undefined,
secret_len: usize = 0,
port: [std.fs.max_path_bytes]u8 = undefined,
port_len: usize = 0,

pub fn init(io: std.Io) !ProxyTestFiles {
    var files: ProxyTestFiles = .{ .temp = std.testing.tmpDir(.{}) };
    errdefer files.temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try files.temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    files.key_len = (try std.fmt.bufPrint(&files.key, "{s}/ca-key.pem", .{directory})).len;
    files.certificate_len = (try std.fmt.bufPrint(&files.certificate, "{s}/ca-cert.pem", .{directory})).len;
    files.bundle_len = (try std.fmt.bufPrint(&files.bundle, "{s}/ca-bundle.pem", .{directory})).len;
    files.secret_len = (try std.fmt.bufPrint(&files.secret, "{s}/proxy-secret", .{directory})).len;
    files.port_len = (try std.fmt.bufPrint(&files.port, "{s}/proxy-port", .{directory})).len;

    return files;
}

pub fn deinit(self: *ProxyTestFiles) void {
    self.temp.cleanup();
}

pub fn config(self: *const ProxyTestFiles) Config {
    return .{
        .key_path = self.key[0..self.key_len],
        .certificate_path = self.certificate[0..self.certificate_len],
        .bundle_path = self.bundle[0..self.bundle_len],
        .secret_path = self.secret[0..self.secret_len],
        .port_path = self.port[0..self.port_len],
    };
}
