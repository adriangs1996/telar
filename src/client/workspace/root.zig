pub const multiplexer = @import("multiplexer.zig");
pub const geometry = @import("geometry.zig");
pub const metrics = @import("metrics.zig");
pub const layout = @import("layout.zig");
pub const navigation = @import("navigation.zig");
pub const tabs = @import("tabs.zig");
pub const workspace_list = @import("workspace_list.zig");

test {
    _ = @import("metrics_tests.zig");
    @import("std").testing.refAllDecls(@This());
}
