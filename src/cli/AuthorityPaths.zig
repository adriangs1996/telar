const AuthorityPaths = @This();
const std = @import("std");
const source_namespace = @import("proxy.zig");
key: [std.fs.max_path_bytes]u8 = undefined,
key_len: usize,
certificate: [std.fs.max_path_bytes]u8 = undefined,
certificate_len: usize,
record: [std.fs.max_path_bytes]u8 = undefined,
record_len: usize,

pub fn init(directory: []const u8) !AuthorityPaths {
    var paths: AuthorityPaths = .{ .key_len = 0, .certificate_len = 0, .record_len = 0 };
    paths.key_len = (try std.fmt.bufPrint(&paths.key, "{s}/{s}", .{ directory, source_namespace.system_key_name })).len;
    paths.certificate_len = (try std.fmt.bufPrint(&paths.certificate, "{s}/{s}", .{ directory, source_namespace.system_cert_name })).len;
    paths.record_len = (try std.fmt.bufPrint(&paths.record, "{s}/{s}", .{ directory, source_namespace.record_name })).len;
    return paths;
}

pub fn files(paths: *const AuthorityPaths) source_namespace.ca.AuthorityFiles {
    return .{ .key = paths.key[0..paths.key_len], .certificate = paths.certificate[0..paths.certificate_len] };
}

pub fn recordPath(paths: *const AuthorityPaths) []const u8 {
    return paths.record[0..paths.record_len];
}
