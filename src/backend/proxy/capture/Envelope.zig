const CredentialType = @import("../Credential.zig");
const HalfType = @import("Half.zig");
const Envelope = @This();

credential: CredentialType,
half: *HalfType,
