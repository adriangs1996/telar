const RelayOptions = @This();
const Route = @import("H2Route.zig");
const provider = @import("../provider/request_support.zig");
const Transformation = @import("Transformation.zig");
route: Route,
dialect: provider.ApiDialect,
transformation: ?Transformation = null,
