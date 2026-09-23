//! Starts one constructed client in the order required by request
//! correlation, the runtime handshake and asynchronous event sources.

const data = @import("model");
const client_module = @import("telar-client");
const TerminalClient = @import("../../TerminalClient.zig");
const Request = @import("Request.zig");
const host_capabilities = @import("../host/host_capabilities.zig");
const presentation_lifecycle = @import("../../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../input/host_inputs.zig");
const host_resizes = @import("../host/host_resizes.zig");
const client_telemetry = @import("../../resources/telemetry.zig");

/// Starts host negotiation and arms I/O without opening a child before its
/// terminal defaults are available or the bounded probe expires.
///
/// ```zig
/// try start(client, .{ .resize_watcher = &watcher });
/// ```
pub fn start(client: *client_module.AttachedClient, request: Request) !void {
    _ = data.multiplexer.rectSize(client.geometry().area) orelse
        return error.TerminalTooSmall;
    client.model.startup.phase = .probing;
    try host_capabilities.begin(client);
    // No socket completion can drive output while startup waits for colors.
    try presentation_lifecycle.pumpOutput(client);
    try host_inputs.scheduleRead(client);

    try host_resizes.schedule(client, request.resize_watcher);
    try client.startRuntimeRead();
    try client_telemetry.start(client);
    try client.synchronizeBars();
    try client.scheduleConfigReload();
}

/// Advances startup after an event. FIFO configuration precedes the state
/// request, so the existing layout/open flow needs no color-probe knowledge.
/// Example: `if (try advance(client)) return .{ .exit = 0 };`.
pub fn advance(client: *client_module.AttachedClient) !bool {
    if (client.model.startup.phase == .probing and TerminalClient.of(client).host_negotiation.initial_settled) {
        try client.runtime_transport.bootstrap(.{
            .graphics_shared = client_module.supportsSharedMemory(),
            .client_identity = client.client_identity,
            .terminal_colors = client.model.host.host_capabilities.terminal_colors,
        });
        client.model.startup.phase = .opening;
        try client.flushGraphicsCredits();
    }

    if (client.model.startup.phase == .opening and client.model.activeTabLocation() != null) {
        client.model.startup.phase = .active;
        return host_inputs.replayStartup(client);
    }

    return false;
}
