const Head = @This();
const Message = @import("Message.zig");
const source_namespace = @import("head_support.zig");
const provider = @import("../provider/request_support.zig");
message: Message,
framing: source_namespace.Framing,
classification: provider.RequestClass,
sse_body: bool,
