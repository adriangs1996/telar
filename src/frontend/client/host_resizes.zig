//! Adapts host TTY resize events to one client's application state.

const std = @import("std");
const core = @import("telar-core");
const platform = @import("../platform/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_geometry = @import("pane_geometry.zig");

const Client = @import("client.zig");
const host_resize = client_application.host_resize;
const schema = core.schema;

const pixel_queries = "\x1b[14t\x1b[16t";

pub const Source = struct {
    tty: *const platform.Tty,
    watcher: *platform.ResizeWatcher,
};

/// Handles one completed platform resize event and rearms its watcher.
///
/// ```zig
/// _ = try handle(client, result, source);
/// ```
pub fn handle(client: *Client, result: anyerror!void, source: Source) !?client_model.HostCommit {
    try result;
    const commit = try apply(client, source.tty.size());
    try queryPixels(client);
    try client.select.concurrent(.resized, Client.waitResize, .{ client.io, source.watcher });

    return commit;
}

/// Resolves and applies one already measured host size.
///
/// ```zig
/// const commit = try apply(client, measurement);
/// ```
pub fn apply(client: *Client, measurement: platform.Size) !?client_model.HostCommit {
    const update = resolve(client.model.hostCapabilities(), measurement);

    return applyUpdate(client, update);
}

fn applyUpdate(client: *Client, update: client_model.HostUpdate) !?client_model.HostCommit {
    var use_case: host_resize.ResizeHostHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .sync = syncResources,
        },
    };
    return use_case.execute(update);
}

/// Resolves the first platform measurement before a client model exists.
///
/// ```zig
/// const size = initialSize(tty.size());
/// ```
pub fn initialSize(measurement: platform.Size) schema.TerminalSize {
    return resolve(.{}, measurement).size;
}

fn resolve(current: client_model.HostCapabilities, measurement: platform.Size) client_model.HostUpdate {
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

fn syncResources(raw_context: *anyopaque, commit: client_model.HostCommit) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    const resize = commit.resize orelse return;

    try sync(client, resize);
}

/// Synchronizes physical geometry after an already committed host resize.
///
/// ```zig
/// try sync(client, resize);
/// ```
pub fn sync(client: *Client, commit: client_model.HostResizeCommit) !void {
    if (commit.grid_changed) {
        try client.presenter.resize(commit.current.cols, commit.current.rows);
        try client.view.resize(commit.current.cols, commit.current.rows);
    }

    if (commit.cell_size_changed) {
        try client.view.configureSidebar(
            client.sidebar_rendering,
            client.model.hostCapabilities().kitty_graphics,
            commit.current.cell_width_px,
            commit.current.cell_height_px,
        );
    }
    client.graphics_store.invalidatePlacements();
    const active = client.model.workspace.active() orelse return;

    try pane_geometry.offerAttached(client, &active.model, client.view.workbench());
}

fn queryPixels(client: *Client) !void {
    try writePixelQueries(client.writer);
}

fn writePixelQueries(writer: *std.Io.Writer) !void {
    try writer.writeAll(pixel_queries);
    try writer.flush();
}

test "initial host size normalizes an empty grid and resolves pixels" {
    try std.testing.expectEqual(schema.TerminalSize{
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

test "a resize requests current window and cell pixels" {
    var bytes: [pixel_queries.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);

    try writePixelQueries(&writer);

    try std.testing.expectEqualStrings(pixel_queries, writer.buffered());
}
