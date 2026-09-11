const TabLocationType = @import("telar-core").TabLocation;
/// Infallible runtime effect that starts closing every pane owned by a tab.
const PaneCloser = @This();

context: *anyopaque,
close_all: *const fn (*anyopaque, TabLocationType) void,
