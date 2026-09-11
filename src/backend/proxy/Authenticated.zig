const Authenticated = @This();
const identity = @import("identity.zig");
const Target = @import("Target.zig");
credential: identity.Credential,
target: Target,
