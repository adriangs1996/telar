//! Starts one constructed client in the order required by request
//! correlation, the runtime handshake and asynchronous event sources.

const TerminalClient = @import("../../TerminalClient.zig");
const host = TerminalClient.of;
const Client = @import("telar-client").AttachedClient;
const Request = @import("Request.zig");
const rectSize_module = @import("telar-client").rectSize;
const host_capabilities = @import("../host/host_capabilities.zig");
const presentation_lifecycle = @import("../../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../input/host_inputs.zig");
const host_resizes = @import("../host/host_resizes.zig");
const runtime_transport = @import("telar-client").runtime_io;
const client_telemetry = @import("../../resources/telemetry.zig");
const bar_updates = @import("telar-client").controllers.bar_updates;
const config_reloads = @import("telar-client").controllers.config_reloads;
const supportsSharedMemory_module = @import("telar-client").supportsSharedMemory;

/// Starts host negotiation and arms I/O without opening a child before its
/// terminal defaults are available or the bounded probe expires.
///
/// ```zig
/// try start(client, .{ .resize_watcher = &watcher });
/// ```
pub fn start(client: *Client, request: Request) !void {
    _ = rectSize_module(client.geometry().area) orelse
        return error.TerminalTooSmall;
    client.startup.phase = .probing;
    try host_capabilities.begin(client);
    // No socket completion can drive output while startup waits for colors.
    try presentation_lifecycle.pumpOutput(client);
    try host_inputs.scheduleRead(client);

    try host_resizes.schedule(client, request.resize_watcher);
    try runtime_transport.scheduleRead(client);
    try client_telemetry.start(client);
    try bar_updates.synchronize(client);
    try config_reloads.schedule(client);
}

/// Advances startup after an event. FIFO configuration precedes the state
/// request, so the existing layout/open flow needs no color-probe knowledge.
/// Example: `if (try advance(client)) return .{ .exit = 0 };`.
pub fn advance(client: *Client) !bool {
    if (client.startup.phase == .probing and host(client).host_negotiation.initial_settled) {
        try client.runtime_transport.bootstrap(.{
            .graphics_shared = supportsSharedMemory_module(),
            .client_identity = client.client_identity,
            .terminal_colors = client.model.hostCapabilities().terminal_colors,
        });
        client.startup.phase = .opening;
        try runtime_transport.flushGraphicsCredits(client);
    }

    if (client.startup.phase == .opening and client.model.activeTabLocation() != null) {
        client.startup.phase = .active;
        return host_inputs.replayStartup(client);
    }

    return false;
}
