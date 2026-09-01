//! Physical and asynchronous resources owned by one client.

pub const clock = @import("clock.zig");
pub const config_reload = @import("config_reload.zig");
pub const deadline_timer = @import("deadline_timer.zig");
pub const input_handler = @import("input_handler.zig");
pub const notification_timers = @import("notification_timers.zig");
pub const telemetry = @import("telemetry.zig");

test {
    _ = clock;
    _ = config_reload;
    _ = deadline_timer;
    _ = input_handler;
    _ = notification_timers;
    _ = telemetry;
}
