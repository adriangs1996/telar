const SessionType = @import("../Session.zig");
const relay = @import("relay.zig");
const types = @import("../../agent/types.zig");
const Route = @This();

from: SessionType.Side,
to: SessionType.Side,
direction: relay.Direction,
dialect: types.ApiDialect,
