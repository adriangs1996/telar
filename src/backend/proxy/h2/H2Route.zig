const Route = @This();
const tls = @import("../tls.zig");
const source_namespace = @import("root.zig");
from: tls.Session.Side,
to: tls.Session.Side,
direction: source_namespace.Direction,
