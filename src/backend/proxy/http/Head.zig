const Message = @import("Message.zig");
const types = @import("types.zig");
const provider = @import("../provider/request_support.zig");
const Head = @This();

message: Message,
framing: types.BodyPlan,
classification: provider.RequestClass,
sse_body: bool,
