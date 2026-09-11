const request_router = @import("request_router.zig");
const PaneInputType = @import("telar-core").PaneInput;
const Capture = @This();

calls: usize = 0,
last: ?request_router.Tag = null,
failure: ?request_router.Tag = null,
pane_input: ?PaneInputType = null,
