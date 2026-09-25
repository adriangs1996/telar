const CredentialId = @import("CredentialId.zig");
const Target = @import("Target.zig");
const Authenticated = @This();

owner: CredentialId,
target: Target,
