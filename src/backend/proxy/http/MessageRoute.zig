const SessionType = @import("../Session.zig");
const types = @import("../../agent/types.zig");
const Half = @import("../capture/Half.zig");
const MessageRoute = @This();

from: SessionType.Side,
to: SessionType.Side,
is_response: bool,
response_to_head: bool,
dialect: types.ApiDialect = .unknown,
/// The capture half that records this head, when the exchange is captured.
capture: ?*Half = null,
