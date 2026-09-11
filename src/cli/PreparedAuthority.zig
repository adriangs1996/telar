const PreparedAuthority = @This();
const source_namespace = @import("proxy.zig");
const std = @import("std");
const AuthorityPaths = @import("AuthorityPaths.zig");
authority: source_namespace.ca.Authority,
temporary_key: [std.fs.max_path_bytes]u8 = undefined,
temporary_key_len: usize = 0,
temporary_certificate: [std.fs.max_path_bytes]u8 = undefined,
temporary_certificate_len: usize = 0,
temporary: bool = false,

pub fn files(prepared: *const PreparedAuthority, canonical: *const AuthorityPaths) source_namespace.ca.AuthorityFiles {
    if (!prepared.temporary) {
        return canonical.files();
    }

    return .{
        .key = prepared.temporary_key[0..prepared.temporary_key_len],
        .certificate = prepared.temporary_certificate[0..prepared.temporary_certificate_len],
    };
}

fn cleanup(prepared: *PreparedAuthority, io: source_namespace.Io) void {
    if (!prepared.temporary) {
        return;
    }

    source_namespace.Io.Dir.deleteFileAbsolute(io, prepared.temporary_key[0..prepared.temporary_key_len]) catch {};
    source_namespace.Io.Dir.deleteFileAbsolute(io, prepared.temporary_certificate[0..prepared.temporary_certificate_len]) catch {};
}
