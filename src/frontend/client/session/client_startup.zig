//! Starts one constructed client in the order required by request
//! correlation, the runtime handshake and asynchronous event sources.

const data = @import("model");
const client_module = @import("telar-client");
const TerminalClient = @import("../TerminalClient.zig");
const platform = @import("../../platform/platform.zig");
const host_capabilities = @import("../host/host_capabilities.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../input/host_inputs.zig");
const host_resizes = @import("../host/host_resizes.zig");
const client_telemetry = @import("../telemetry/telemetry.zig");
const host_effects = @import("../host/host_effects.zig");

/// Starts host negotiation and arms I/O without opening a child before its
/// terminal defaults are available or the bounded probe expires.
///
/// ```zig
/// try start(terminal, .{ .resize_watcher = &watcher });
/// ```
pub fn start(terminal: *TerminalClient, request: StartupRequest) !void {
    const client = &terminal.app;

    _ = data.multiplexer.rectSize(client.geometry().area) orelse
        return error.TerminalTooSmall;
    client.model.startup.phase = .probing;
    try host_capabilities.begin(terminal);
    // No socket completion can drive output while startup waits for colors.
    try presentation_lifecycle.pumpOutput(terminal);
    try host_inputs.scheduleRead(terminal);

    try host_resizes.schedule(terminal, request.resize_watcher);
    try client.startRuntimeRead();
    try client_telemetry.start(terminal);
    try client.synchronizeBars();
    try client.scheduleConfigReload();
    try host_effects.deliver(terminal);
}

/// Advances startup after an event. FIFO configuration precedes the state
/// request, so the existing layout/open flow needs no color-probe knowledge.
/// Example: `if (try advance(terminal)) return .{ .exit = 0 };`.
pub fn advance(terminal: *TerminalClient) !bool {
    const client = &terminal.app;

    if (client.model.startup.phase == .probing and terminal.host_negotiation.initial_settled) {
        try client.model.to_runtime.pushBootstrap(.{
            .graphics_shared = client_module.supportsSharedMemory(),
            .client_identity = client.client_identity,
            .terminal_colors = client.model.host.host_capabilities.terminal_colors,
        });
        client.model.startup.phase = .opening;
    }

    if (client.model.startup.phase == .opening and client.model.activeTabLocation() != null) {
        client.model.startup.phase = .active;
        return host_inputs.replayStartup(terminal);
    }

    return false;
}

const StartupRequest = struct {
    resize_watcher: *platform.ResizeWatcher,
};
