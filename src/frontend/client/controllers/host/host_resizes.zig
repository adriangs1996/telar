//! Adapts host TTY resize events to one client's application state.

const Client = @import("../../Client.zig");
const platform = @import("../../../platform/platform.zig");
const Source = @import("Source.zig");
const HostCommitType = @import("telar-client").HostCommit;
const host_capabilities = @import("host_capabilities.zig");
const std = @import("std");
const SizeType = @import("../../../platform/Size.zig");
const HostUpdateType = @import("telar-client").HostUpdate;
const ResizeHostHandlerType = @import("telar-client").ResizeHostHandler;
const TerminalSizeType = @import("telar-core").TerminalSize;
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const host_resources = @import("host_resources.zig");

/// Registers the next platform resize observation for this client.
///
/// ```zig
/// try schedule(client, watcher);
/// ```
pub fn schedule(client: *Client, watcher: *platform.ResizeWatcher) !void {
    try client.select.concurrent(.resized, wait, .{ client.io, watcher });
}

/// Handles one completed platform resize event and rearms its watcher.
///
/// ```zig
/// _ = try handle(client, result, source);
/// ```
pub fn handle(client: *Client, result: anyerror!void, source: Source) !?HostCommitType {
    try result;
    const commit = try apply(client, source.tty.size());
    try host_capabilities.refresh(client);
    try schedule(client, source.watcher);

    return commit;
}

fn wait(io: std.Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

/// Resolves and applies one already measured host size.
///
/// ```zig
/// const commit = try apply(client, measurement);
/// ```
pub fn apply(client: *Client, measurement: SizeType) !?HostCommitType {
    const update = resolve(client.model.hostCapabilities(), measurement);

    return applyUpdate(client, update);
}

fn applyUpdate(client: *Client, update: HostUpdateType) !?HostCommitType {
    var use_case: ResizeHostHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverResources,
        },
    };
    return use_case.execute(update);
}

/// Resolves the first platform measurement before a client model exists.
///
/// ```zig
/// const size = initialSize(tty.size());
/// ```
pub fn initialSize(measurement: SizeType) TerminalSizeType {
    return resolve(.{}, measurement).size;
}

fn resolve(current: HostCapabilitiesType, measurement: SizeType) HostUpdateType {
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

fn deliverResources(raw_context: *anyopaque, commit: HostCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try host_resources.deliver(client, commit);
}

test "initial host size normalizes an empty grid and resolves pixels" {
    try std.testing.expectEqual(TerminalSizeType{
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
