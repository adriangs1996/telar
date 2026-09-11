const SessionType = @import("../Session.zig");
const types = @import("types.zig");
const Route = @This();

from: SessionType.Side,
to: SessionType.Side,
framing: types.BodyPlan,
