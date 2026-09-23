const Session = @import("../Session.zig");
const types = @import("types.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
framing: types.BodyPlan,
