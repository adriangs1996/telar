const CredentialType = @import("Credential.zig");
const Target = @import("Target.zig");
const Authenticated = @This();

credential: CredentialType,
target: Target,
