const localca = @import("localca");
const Session = localca.Session;
const types = @import("../../agent/types.zig");
const Half = @import("../capture/Half.zig");
const MessageRoute = @This();

from: Session.Side,
to: Session.Side,
is_response: bool,
response_to_head: bool,
dialect: types.ApiDialect = .unknown,
/// The capture half that records this head, when the exchange is captured.
capture: ?*Half = null,
