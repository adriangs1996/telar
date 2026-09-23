//! Adapts host TTY resize events to one client's application state.

const client_module = @import("telar-client");
const data = @import("model");
const core = @import("telar-core");
const TerminalClient = @import("../../TerminalClient.zig");
const platform = @import("../../../platform/platform.zig");
const Source = @import("Source.zig");
const host_capabilities = @import("host_capabilities.zig");
const std = @import("std");
const Size = @import("../../../platform/Size.zig");

/// Registers the next platform resize observation for this client.
///
/// ```zig
/// try schedule(terminal, watcher);
/// ```
pub fn schedule(terminal: *TerminalClient, watcher: *platform.ResizeWatcher) !void {
    const client = &terminal.app;

    try terminal.inbox.start(.resized, .{ wait, .{ client.io, watcher } });
}

/// Handles one completed platform resize event and rearms its watcher.
///
/// ```zig
/// _ = try handle(terminal, result, source);
/// ```
pub fn handle(terminal: *TerminalClient, result: anyerror!void, source: Source) !?data.HostCommit {
    try result;
    const commit = try apply(terminal, source.tty.size());
    try host_capabilities.refresh(terminal);
    try schedule(terminal, source.watcher);

    return commit;
}

fn wait(io: std.Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

/// Resolves and applies one already measured host size.
///
/// ```zig
/// const commit = try apply(terminal, measurement);
/// ```
pub fn apply(terminal: *TerminalClient, measurement: Size) !?data.HostCommit {
    const client = &terminal.app;

    const update = resolve(client.model.host.host_capabilities, measurement);

    return client.applyHostUpdate(update);
}

/// Resolves the first platform measurement before a client model exists.
///
/// ```zig
/// const size = initialSize(tty.size());
/// ```
pub fn initialSize(measurement: Size) core.TerminalSize {
    return resolve(.{}, measurement).size;
}

fn resolve(current: data.HostCapabilities, measurement: Size) data.HostUpdate {
    var capabilities = current;
    const cols = if (measurement.cols == 0) 80 else measurement.cols;
    const rows = if (measurement.rows == 0) 24 else measurement.rows;
    if (measurement.width_px != 0) {
        capabilities.window_width_px = measurement.width_px;
    }
    if (measurement.height_px != 0) {
        capabilities.window_height_px = measurement.height_px;
    }
    const cell_size = capabilities.cellSize(cols, rows);

    return .{
        .capabilities = capabilities,
        .size = .{
            .cols = cols,
            .rows = rows,
            .cell_width_px = cell_size.width,
            .cell_height_px = cell_size.height,
        },
    };
}

test "initial host size normalizes an empty grid and resolves pixels" {
    try std.testing.expectEqual(core.TerminalSize{
        .cols = 80,
        .rows = 24,
        .cell_width_px = 10,
        .cell_height_px = 20,
    }, initialSize(.{
        .cols = 0,
        .rows = 0,
        .width_px = 800,
        .height_px = 480,
    }));
}
