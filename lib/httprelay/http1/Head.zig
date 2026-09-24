const Message = @import("Message.zig");
const types = @import("types.zig");
const Head = @This();

message: Message,
framing: types.BodyPlan,
/// A request whose original start line matched one of the watched routes.
watched: bool,
sse_body: bool,
