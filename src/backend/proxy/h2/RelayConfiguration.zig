const types = @import("../../agent/types.zig");
const Transform = @import("Transform.zig");
const RelayConfiguration = @This();

dialect: types.ApiDialect,
transformation: ?Transform = null,
