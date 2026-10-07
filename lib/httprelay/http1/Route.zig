const localca = @import("localca");
const Session = localca.Session;
const types = @import("types.zig");

from: Session.Side,
to: Session.Side,
framing: types.BodyPlan,
