//! The long-lived side of telar.
//!
//! The backend owns processes, PTYs and terminal emulation. It may produce
//! core data for a frontend, but it never imports frontend code.

pub const pty = @import("pty/root.zig");
pub const agent = @import("agent/root.zig");
pub const pane = @import("pane/root.zig");
pub const workspace = @import("workspace/root.zig");
pub const process = @import("process/root.zig");
pub const history = @import("history/root.zig");
pub const engine = @import("engine/root.zig");
pub const proxy = @import("proxy/root.zig");
pub const plugins = @import("plugins/root.zig");
pub const media = @import("media/root.zig");
pub const transport = @import("transport/root.zig");
pub const runtime = @import("runtime/root.zig");

// Compatibility aliases for callers migrating to the capability namespaces.
pub const blit = pane.blit;
pub const damage = pane.damage;
pub const system_metrics = runtime.system_metrics;

test {
    @import("std").testing.refAllDecls(@This());
}
