const Route = @This();
const tls = @import("../tls.zig");
const source_namespace = @import("relay.zig");
const provider = @import("../provider/request_support.zig");
from: tls.Session.Side,
to: tls.Session.Side,
direction: source_namespace.Direction,
dialect: provider.ApiDialect,
