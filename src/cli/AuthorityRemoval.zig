const AuthorityTarget = @import("AuthorityTarget.zig");
const AuthorityRemoval = @This();

target: AuthorityTarget,
fingerprint: []const u8,
destination: []const u8,
