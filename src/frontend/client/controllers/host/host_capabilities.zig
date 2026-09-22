//! Adapts terminal protocol replies and probe expiry to client host state.

const client_module = @import("telar-client");
const data = @import("model");
const TerminalClient = @import("../../TerminalClient.zig");
const capabilities_module = @import("../../../graphics/capabilities.zig");
const negotiation = @import("../../resources/host_negotiation.zig");
const term = @import("../../../presentation/screen_support.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const std = @import("std");

/// Starts the exterior-terminal probes through one owner.
/// Example: `try begin(client);`.
pub fn begin(client: *client_module.AttachedClient) !void {
    try TerminalClient.of(client).writer.writeAll(capabilities_module.query);
    try queryColors(client);
    try TerminalClient.of(client).writer.flush();
}

/// Coalesces overlapping color probes. A resize needs no protocol details.
/// Example: `try refresh(client);`.
pub fn refresh(client: *client_module.AttachedClient) !void {
    try TerminalClient.of(client).writer.writeAll(negotiation.pixel_query);
    try queryColors(client);
    try TerminalClient.of(client).writer.flush();
}

fn queryColors(client: *client_module.AttachedClient) !void {
    if (!TerminalClient.of(client).host_negotiation.begin(client_module.monotonic(client.io))) {
        return;
    }

    try TerminalClient.of(client).writer.writeAll(negotiation.color_query);
    try scheduleExpiry(client);
}

/// Example: `try scheduleExpiry(client);`.
pub fn scheduleExpiry(client: *client_module.AttachedClient) !void {
    const state = &TerminalClient.of(client).host_negotiation;
    switch (state.timer.update(client.io, state.deadline_ns)) {
        .idle, .retained => {},
        .schedule => TerminalClient.of(client).inbox.start(.capability_timeout, .{ client_module.wait, .{
            client.io, &state.timer,
        } }) catch |err| {
            state.timer.schedulingFailed();
            return err;
        },
    }
}

/// Applies probe fallbacks after the registered deadline completes.
///
/// ```zig
/// _ = try handleExpiry(client, result);
/// ```
pub fn handleExpiry(client: *client_module.AttachedClient, result: anyerror!void) !?data.HostCommit {
    try TerminalClient.of(client).host_negotiation.timer.complete(result);
    if (!TerminalClient.of(client).host_negotiation.expire(client_module.monotonic(client.io))) {
        try scheduleExpiry(client);
        return null;
    }

    return expire(client);
}

/// Commits one recognized terminal response and projects changed resources.
///
/// ```zig
/// _ = try observe(client, response);
/// ```
pub fn observe(client: *client_module.AttachedClient, response: term.Event.TerminalResponse) !?data.HostCommit {
    const color: ?negotiation.Color = switch (response) {
        .foreground_color => .foreground,
        .background_color => .background,
        else => null,
    };
    if (color) |target| {
        if (!TerminalClient.of(client).host_negotiation.accept(target, client_module.monotonic(client.io))) {
            return null;
        }
    }

    if (response == .kitty_graphics and response.kitty_graphics.image_id == capabilities_module.zlib_query_image_id) {
        TerminalClient.of(client).host_negotiation.zlib_support = if (response.kitty_graphics.supported) .supported else .unsupported;
        kitty_delivery.setHostZlib(&TerminalClient.of(client).graphics_store, response.kitty_graphics.supported);
        return null;
    }

    const observation = translate(response) orelse return null;
    return client.observeHostCapability(observation);
}

/// Settles unanswered probes and projects their fallback resources.
///
/// ```zig
/// _ = try expire(client);
/// ```
pub fn expire(client: *client_module.AttachedClient) !?data.HostCommit {
    const capabilities = negotiation.settledCapabilities(client.model.hostCapabilities());

    if (TerminalClient.of(client).host_negotiation.zlib_support == .unknown) {
        TerminalClient.of(client).host_negotiation.zlib_support = .unsupported;
    }

    return client.reconcileHostCapabilities(capabilities);
}

/// Translates one parser reply into a protocol-free host observation.
///
/// ```zig
/// const observation = translate(response) orelse return;
/// ```
pub fn translate(response: term.Event.TerminalResponse) ?data.HostCapabilityObservation {
    return switch (response) {
        .kitty_graphics => |reply| if (reply.image_id == capabilities_module.query_image_id)
            .{ .images = support(reply.supported) }
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
        .mouse_pixels => |reply| .{ .pointer_pixels = support(reply.supported) },
        .foreground_color => |color| .{ .foreground = .{ .r = color.r, .g = color.g, .b = color.b } },
        .background_color => |color| .{ .background = .{ .r = color.r, .g = color.g, .b = color.b } },
        .primary_device_attributes => null,
    };
}

fn support(supported: bool) data.HostCapabilitySupport {
    return if (supported) .supported else .unsupported;
}

test "Kitty probe replies translate by reserved image identity" {
    try std.testing.expectEqual(
        data.HostCapabilityObservation{ .images = .supported },
        translate(.{ .kitty_graphics = .{
            .image_id = capabilities_module.query_image_id,
            .supported = true,
        } }).?,
    );
    try std.testing.expect(translate(.{ .kitty_graphics = .{
        .image_id = capabilities_module.zlib_query_image_id,
        .supported = false,
    } }) == null);
    try std.testing.expect(translate(.{ .kitty_graphics = .{
        .image_id = 999,
        .supported = true,
    } }) == null);
}

test "Geometry and mouse replies translate without protocol types" {
    try std.testing.expectEqual(
        data.HostCapabilityObservation{ .window_pixels = .{
            .width = 1200,
            .height = 800,
        } },
        translate(.{ .window_pixels = .{ .width = 1200, .height = 800 } }).?,
    );
    try std.testing.expectEqual(
        data.HostCapabilityObservation{ .cell_pixels = .{
            .width = 10,
            .height = 20,
        } },
        translate(.{ .cell_pixels = .{ .width = 10, .height = 20 } }).?,
    );
    try std.testing.expectEqual(
        data.HostCapabilityObservation{ .pointer_pixels = .supported },
        translate(.{ .mouse_pixels = .{ .supported = true } }).?,
    );
    try std.testing.expect(translate(.primary_device_attributes) == null);
}
