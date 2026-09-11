const Publication = @This();
const identity = @import("../identity.zig");
const buffer = @import("buffer_support.zig");
credential: identity.Credential,
half: *buffer.Half,
