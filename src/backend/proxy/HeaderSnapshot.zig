const TransformContext = @import("TransformContext.zig");
const HeaderView = @import("HeaderView.zig");
const HeaderSnapshot = @This();

context: TransformContext,
fields: []const HeaderView,
