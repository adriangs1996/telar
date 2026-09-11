const MessageRoute = @This();
const tls = @import("../tls.zig");
const provider = @import("../provider/request_support.zig");
const HeadSink = @import("HeadSink.zig");
from: tls.Session.Side,
to: tls.Session.Side,
is_response: bool,
response_to_head: bool,
dialect: provider.ApiDialect = .unknown,
capture: ?HeadSink = null,
