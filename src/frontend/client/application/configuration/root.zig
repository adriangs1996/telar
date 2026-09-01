//! Configuration and diagnostic flows owned by the client application.

pub const client_diagnostic = @import("client_diagnostic.zig");
pub const bar_update = @import("bar_update.zig");
pub const config_reload = @import("config_reload.zig");
pub const config_reload_delivery = @import("config_reload_delivery.zig");

test {
    _ = client_diagnostic;
    _ = bar_update;
    _ = config_reload;
    _ = config_reload_delivery;
}
