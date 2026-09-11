const Route = @This();
const tls = @import("../tls.zig");
const head = @import("head_support.zig");
from: tls.Session.Side,
to: tls.Session.Side,
framing: head.Framing,
