const localca = @import("localca");
const backend = @import("telar-backend");
const std = @import("std");
const proxy = @import("proxy.zig");
const AuthorityPaths = @This();

key: [std.fs.max_path_bytes]u8 = undefined,
key_len: usize,
certificate: [std.fs.max_path_bytes]u8 = undefined,
certificate_len: usize,
record: [std.fs.max_path_bytes]u8 = undefined,
record_len: usize,

pub fn init(directory: []const u8) !AuthorityPaths {
    var paths: AuthorityPaths = .{ .key_len = 0, .certificate_len = 0, .record_len = 0 };
    paths.key_len = (try std.fmt.bufPrint(&paths.key, "{s}/{s}", .{ directory, proxy.system_key_name })).len;
    paths.certificate_len = (try std.fmt.bufPrint(&paths.certificate, "{s}/{s}", .{ directory, proxy.system_cert_name })).len;
    paths.record_len = (try std.fmt.bufPrint(&paths.record, "{s}/{s}", .{ directory, proxy.record_name })).len;
    return paths;
}

pub fn files(self: *const AuthorityPaths) localca.AuthorityFiles {
    return .{
        .key = self.key[0..self.key_len],
        .certificate = self.certificate[0..self.certificate_len],
        .common_name = backend.ca_identity.common_name,
    };
}

pub fn recordPath(self: *const AuthorityPaths) []const u8 {
    return self.record[0..self.record_len];
}
