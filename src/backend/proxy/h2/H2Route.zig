const Session = @import("../Session.zig");
const relay = @import("relay.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
direction: relay.Direction,
