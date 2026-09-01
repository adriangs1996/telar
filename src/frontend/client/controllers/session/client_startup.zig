//! Starts one constructed client in the order required by request
//! correlation, the runtime handshake and asynchronous event sources.

const graphics = @import("../../../graphics/root.zig");
const platform = @import("../../../platform/root.zig");
const workspace = @import("../../../workspace/root.zig");

const Client = @import("../../client.zig");
const client_telemetry = @import("../../resources/telemetry.zig");
const bar_updates = @import("../configuration/bar_updates.zig");
const config_reloads = @import("../configuration/config_reloads.zig");
const host_capabilities = @import("../host/host_capabilities.zig");
const host_resizes = @import("../host/host_resizes.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const kitty = graphics.kitty;

pub const Request = struct {
    resize_watcher: *platform.ResizeWatcher,
};

/// Registers the initial request, sends the synchronous runtime handshake and
/// arms every event source needed before the first client-loop iteration.
///
/// ```zig
/// try start(client, .{ .resize_watcher = &watcher });
/// ```
pub fn start(client: *Client, request: Request) !void {
    _ = workspace.multiplexer.rectSize(client.view.workbench()) orelse
        return error.TerminalTooSmall;
    try client.runtime_transport.bootstrap(client.io, .{
        .graphics_shared = kitty.clientSupportsSharedMemory(),
        .client_identity = client.client_identity,
    });

    try host_resizes.schedule(client, request.resize_watcher);
    try runtime_transport.scheduleRead(client);
    try host_capabilities.scheduleExpiry(client);
    try client_telemetry.start(client);
    try bar_updates.synchronize(client);
    try config_reloads.schedule(client);
}
