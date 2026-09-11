const CredentialType = @import("../Credential.zig");
const Liveness = @This();

context: *anyopaque,
is_live: *const fn (*anyopaque, *const CredentialType) bool,
