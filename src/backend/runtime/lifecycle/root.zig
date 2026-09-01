//! Runtime stop authority, external stop signals, and ordered teardown.

pub const shutdown_authority = @import("shutdown_authority.zig");
pub const shutdown_coordinator = @import("shutdown_coordinator.zig");
pub const stop_signal = @import("stop_signal.zig");
