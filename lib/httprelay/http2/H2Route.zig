const localca = @import("localca");
const Session = localca.Session;
const relay = @import("relay.zig");

from: Session.Side,
to: Session.Side,
direction: relay.Direction,
