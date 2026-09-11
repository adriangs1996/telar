const SessionType = @import("../Session.zig");
const types = @import("../../agent/types.zig");
const HeadSink = @import("HeadSink.zig");
const MessageRoute = @This();

from: SessionType.Side,
to: SessionType.Side,
is_response: bool,
response_to_head: bool,
dialect: types.ApiDialect = .unknown,
capture: ?HeadSink = null,
