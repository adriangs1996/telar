//! Adapts terminal protocol replies and probe expiry to client host state.

const std = @import("std");
const graphics = @import("../graphics/root.zig");
const presentation = @import("../presentation/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const host_resizes = @import("host_resizes.zig");
const pane_graphics = @import("pane_graphics.zig");
const host_capability = client_application.host_capabilities;
const kitty = graphics.kitty;
const term = presentation.screen;

/// Registers the capability-probe deadline for this client.
///
/// ```zig
/// try scheduleExpiry(client);
/// ```
pub fn scheduleExpiry(client: *Client) !void {
    try client.select.concurrent(.capability_timeout, waitExpiry, .{client.io});
}

/// Applies probe fallbacks after the registered deadline completes.
///
/// ```zig
/// _ = try handleExpiry(client, result);
/// ```
pub fn handleExpiry(client: *Client, result: anyerror!void) !?client_model.HostCommit {
    try result;

    return expire(client);
}

/// Commits one recognized terminal response and projects changed resources.
///
/// ```zig
/// _ = try observe(client, response);
/// ```
pub fn observe(client: *Client, response: term.Event.TerminalResponse) !?client_model.HostCommit {
    const observation = translate(response) orelse return null;
    var use_case = handler(client);

    return use_case.observe(observation);
}

/// Settles unanswered probes and projects their fallback resources.
///
/// ```zig
/// _ = try expire(client);
/// ```
pub fn expire(client: *Client) !?client_model.HostCommit {
    var use_case = handler(client);

    return use_case.expire();
}

fn waitExpiry(io: std.Io) anyerror!void {
    const now_ns = Client.monotonic(io);
    const deadline = std.Io.Timestamp.fromNanoseconds(
        @intCast(now_ns +| kitty.capability_timeout_ns),
    ).withClock(.awake);

    try deadline.wait(io);
}

fn handler(client: *Client) host_capability.Handler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .sync = syncResources,
        },
    };
}

/// Translates one parser reply into a protocol-free host observation.
///
/// ```zig
/// const observation = translate(response) orelse return;
/// ```
pub fn translate(response: term.Event.TerminalResponse) ?client_model.HostCapabilityObservation {
    return switch (response) {
        .kitty_graphics => |reply| if (reply.image_id == kitty.query_image_id)
            .{ .kitty_graphics = support(reply.supported) }
        else if (reply.image_id == kitty.zlib_query_image_id)
            .{ .kitty_zlib = support(reply.supported) }
        else
            null,
        .window_pixels => |size| .{ .window_pixels = .{
            .width = size.width,
            .height = size.height,
        } },
        .cell_pixels => |size| .{ .cell_pixels = .{
            .width = size.width,
            .height = size.height,
        } },
        .mouse_pixels => |reply| .{ .mouse_pixels = support(reply.supported) },
        .primary_device_attributes => null,
    };
}

fn support(supported: bool) client_model.HostCapabilitySupport {
    return if (supported) .supported else .unsupported;
}

fn syncResources(raw_context: *anyopaque, commit: client_model.HostCommit) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    if (commit.capabilities) |capabilities| {
        const graphics_changed = capabilities.previous.kitty_graphics !=
            capabilities.current.kitty_graphics;
        if (graphics_changed) {
            pane_graphics.syncFallbacks(client);
            const host_size = client.model.hostSize();
            try client.view.configureSidebar(
                client.sidebar_rendering,
                capabilities.current.kitty_graphics,
                host_size.cell_width_px,
                host_size.cell_height_px,
            );
            client.graphics_store.invalidatePlacements();
        }
    }

    if (commit.resize) |resize| {
        try host_resizes.sync(client, resize);
    }
}

test "Kitty probe replies translate by reserved image identity" {
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .kitty_graphics = .supported },
        translate(.{ .kitty_graphics = .{
            .image_id = kitty.query_image_id,
            .supported = true,
        } }).?,
    );
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .kitty_zlib = .unsupported },
        translate(.{ .kitty_graphics = .{
            .image_id = kitty.zlib_query_image_id,
            .supported = false,
        } }).?,
    );
    try std.testing.expect(translate(.{ .kitty_graphics = .{
        .image_id = 999,
        .supported = true,
    } }) == null);
}

test "Geometry and mouse replies translate without protocol types" {
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .window_pixels = .{
            .width = 1200,
            .height = 800,
        } },
        translate(.{ .window_pixels = .{ .width = 1200, .height = 800 } }).?,
    );
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .cell_pixels = .{
            .width = 10,
            .height = 20,
        } },
        translate(.{ .cell_pixels = .{ .width = 10, .height = 20 } }).?,
    );
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .mouse_pixels = .supported },
        translate(.{ .mouse_pixels = .{ .supported = true } }).?,
    );
    try std.testing.expect(translate(.primary_device_attributes) == null);
}
