const AuthorityType = @import("telar-backend").Authority;
const std = @import("std");
const AuthorityPaths = @import("AuthorityPaths.zig");
const AuthorityFilesType = @import("telar-backend").AuthorityFiles;
const PreparedAuthority = @This();

authority: AuthorityType,
temporary_key: [std.fs.max_path_bytes]u8 = undefined,
temporary_key_len: usize = 0,
temporary_certificate: [std.fs.max_path_bytes]u8 = undefined,
temporary_certificate_len: usize = 0,
temporary: bool = false,

pub fn files(prepared: *const PreparedAuthority, canonical: *const AuthorityPaths) AuthorityFilesType {
    if (!prepared.temporary) {
        return canonical.files();
    }

    return .{
        .key = prepared.temporary_key[0..prepared.temporary_key_len],
        .certificate = prepared.temporary_certificate[0..prepared.temporary_certificate_len],
    };
}

pub fn cleanup(prepared: *PreparedAuthority, io: std.Io) void {
    if (!prepared.temporary) {
        return;
    }

    std.Io.Dir.deleteFileAbsolute(io, prepared.temporary_key[0..prepared.temporary_key_len]) catch {};
    std.Io.Dir.deleteFileAbsolute(io, prepared.temporary_certificate[0..prepared.temporary_certificate_len]) catch {};
}
