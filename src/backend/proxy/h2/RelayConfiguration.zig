const RelayConfiguration = @This();
const provider = @import("../provider/request_support.zig");
const Transform = @import("Transform.zig");
dialect: provider.ApiDialect,
transformation: ?Transform = null,
