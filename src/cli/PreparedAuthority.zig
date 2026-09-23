const backend = @import("telar-backend");
const std = @import("std");
const AuthorityPaths = @import("AuthorityPaths.zig");
const PreparedAuthority = @This();

authority: backend.Authority,
temporary_key: [std.fs.max_path_bytes]u8 = undefined,
temporary_key_len: usize = 0,
temporary_certificate: [std.fs.max_path_bytes]u8 = undefined,
temporary_certificate_len: usize = 0,
temporary: bool = false,

pub fn files(self: *const PreparedAuthority, canonical: *const AuthorityPaths) backend.AuthorityFiles {
    if (!self.temporary) {
        return canonical.files();
    }

    return .{
        .key = self.temporary_key[0..self.temporary_key_len],
        .certificate = self.temporary_certificate[0..self.temporary_certificate_len],
    };
}

pub fn cleanup(self: *PreparedAuthority, io: std.Io) void {
    if (!self.temporary) {
        return;
    }

    std.Io.Dir.deleteFileAbsolute(io, self.temporary_key[0..self.temporary_key_len]) catch {};
    std.Io.Dir.deleteFileAbsolute(io, self.temporary_certificate[0..self.temporary_certificate_len]) catch {};
}
