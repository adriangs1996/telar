const Publication = @This();
const identity = @import("../identity.zig");
const source_namespace = @import("root.zig");
credential: identity.Credential,
half: *source_namespace.Half,
