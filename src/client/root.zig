//! Shared client behavior. No terminal, window, or renderer dependencies.

pub const agents = @import("agents/root.zig");
pub const application = @import("application/root.zig");
pub const attachments = @import("attachments/root.zig");
pub const bars = @import("bars/root.zig");
pub const config = @import("config/root.zig");
pub const connection = @import("connection/root.zig");
pub const entrypoints = @import("entrypoints/root.zig");
pub const environment = @import("environment/root.zig");
pub const graphics = @import("graphics/root.zig");
pub const input = @import("input/root.zig");
pub const layout = @import("layout/root.zig");
pub const links = @import("links/root.zig");
pub const model = @import("model/root.zig");
pub const notifications = @import("notifications/root.zig");
pub const panes = @import("panes/root.zig");
pub const presentation = @import("presentation/root.zig");
pub const resources = @import("resources/root.zig");
pub const workspace = @import("workspace/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
