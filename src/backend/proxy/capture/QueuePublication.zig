const Credential = @import("../Credential.zig");
const Half = @import("Half.zig");
const Publication = @This();

credential: Credential,
half: *Half,
