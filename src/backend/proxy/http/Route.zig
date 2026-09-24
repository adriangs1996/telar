const localca = @import("localca");
const Session = localca.Session;
const types = @import("types.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
framing: types.BodyPlan,
