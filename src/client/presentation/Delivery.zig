const Delivery = @This();
const multiplexer = @import("../workspace/root.zig").multiplexer;
commit: multiplexer.PresentationCommit,
media_pending: bool,
