const CredentialType = @import("../Credential.zig");
const HalfType = @import("Half.zig");
const Publication = @This();

credential: CredentialType,
half: *HalfType,
