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
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const host_inputs = @import("../input/host_inputs.zig");

pub const State = struct {
    phase: enum { inactive, probing, opening, active } = .inactive,

    /// Example: `if (state.holdsInput()) retainKeystrokes();`.
    pub fn holdsInput(state: State) bool {
        return state.phase == .probing or state.phase == .opening;
    }
};

const kitty = graphics.kitty;

pub const Request = struct {
    resize_watcher: *platform.ResizeWatcher,
};

/// Starts host negotiation and arms I/O without opening a child before its
/// terminal defaults are available or the bounded probe expires.
///
/// ```zig
/// try start(client, .{ .resize_watcher = &watcher });
/// ```
pub fn start(client: *Client, request: Request) !void {
    _ = workspace.multiplexer.rectSize(client.view.workbench()) orelse
        return error.TerminalTooSmall;
    client.startup.phase = .probing;
    try host_capabilities.begin(client);
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
    if (client.startup.phase == .probing and client.host_negotiation.initial_settled) {
        try client.runtime_transport.bootstrap(.{
            .graphics_shared = kitty.clientSupportsSharedMemory(),
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
