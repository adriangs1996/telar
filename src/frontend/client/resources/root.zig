//! Physical and asynchronous resources owned by one client.

pub const clock = @import("telar-client").resources.clock;
pub const client_layouts = @import("client_layouts.zig");
pub const config_reload = @import("config_reload.zig");
pub const deadline_timer = @import("telar-client").resources.deadline_timer;
pub const input_handler = @import("InputHandler.zig");
pub const host_output = @import("host_output.zig");
pub const notification_timers = @import("notification_timers.zig");
pub const telemetry = @import("telemetry.zig");

test {
    _ = clock;
    _ = client_layouts;
    _ = config_reload;
    _ = deadline_timer;
    _ = input_handler;
    _ = host_output;
    _ = notification_timers;
    _ = telemetry;
}
