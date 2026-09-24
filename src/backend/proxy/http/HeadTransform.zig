const MessageRoute = @import("MessageRoute.zig");
const Rewrite = @import("../Rewrite.zig");
const Half = @import("../capture/Half.zig");
/// One head relay with the rewrites that apply to it.
const HeadTransform = @This();

route: MessageRoute,
rewrites: []const Rewrite,
capture: ?*Half = null,
