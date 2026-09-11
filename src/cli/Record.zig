const Record = @This();
const source_namespace = @import("proxy.zig");
const std = @import("std");
backend: source_namespace.TrustBackend,
fingerprint: [40]u8,
store_path: [std.fs.max_path_bytes]u8 = undefined,
store_path_len: u16 = 0,

/// Borrows the validated absolute trust-store path from this fixed record.
///
/// ```zig
/// const destination = record.storePath();
/// ```
pub fn storePath(record: *const Record) []const u8 {
    return record.store_path[0..record.store_path_len];
}
