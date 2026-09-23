const Credential = @import("../Credential.zig");
const Half = @import("Half.zig");
const Envelope = @This();

credential: Credential,
half: *Half,
