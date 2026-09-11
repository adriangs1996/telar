const H2Route = @import("H2Route.zig");
const types = @import("../../agent/types.zig");
const Transformation = @import("Transformation.zig");
const RelayOptions = @This();

route: H2Route,
dialect: types.ApiDialect,
transformation: ?Transformation = null,
