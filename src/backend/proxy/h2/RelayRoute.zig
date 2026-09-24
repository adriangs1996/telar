const localca = @import("localca");
const Session = localca.Session;
const relay = @import("relay.zig");
const types = @import("../../agent/types.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
direction: relay.Direction,
dialect: types.ApiDialect,
