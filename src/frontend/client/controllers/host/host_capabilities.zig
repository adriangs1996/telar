//! Adapts terminal protocol replies and probe expiry to client host state.

const std = @import("std");
const graphics = @import("../../../graphics/root.zig");
const presentation = @import("../../../presentation/root.zig");
const host_application = @import("telar-client").application.host;
const client_clock = @import("telar-client").resources.clock;
const client_model = @import("telar-client").model;
const host_resources = @import("host_resources.zig");
const negotiation = @import("../../resources/host_negotiation.zig");
const deadline_timer = @import("telar-client").resources.deadline_timer;

const Client = @import("../../client.zig");
const host_capability = host_application.host_capabilities;
const kitty = graphics.kitty;
const term = presentation.screen;

/// Starts the exterior-terminal probes through one owner.
/// Example: `try begin(client);`.
pub fn begin(client: *Client) !void {
    try client.writer.writeAll(kitty.capability_query);
    try queryColors(client);
    try client.writer.flush();
}

/// Coalesces overlapping color probes. A resize needs no protocol details.
/// Example: `try refresh(client);`.
pub fn refresh(client: *Client) !void {
    try client.writer.writeAll(negotiation.pixel_query);
    try queryColors(client);
    try client.writer.flush();
}

fn queryColors(client: *Client) !void {
    if (!client.host_negotiation.begin(client_clock.monotonic(client.io))) {
        return;
    }

    try client.writer.writeAll(negotiation.color_query);
    try scheduleExpiry(client);
}

/// Example: `try scheduleExpiry(client);`.
pub fn scheduleExpiry(client: *Client) !void {
    const state = &client.host_negotiation;
    switch (state.timer.update(client.io, state.deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.select.concurrent(.capability_timeout, deadline_timer.wait, .{
            client.io, &state.timer,
        }) catch |err| {
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
pub fn handleExpiry(client: *Client, result: anyerror!void) !?client_model.HostCommit {
    try client.host_negotiation.timer.complete(result);
    if (!client.host_negotiation.expire(client_clock.monotonic(client.io))) {
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
pub fn observe(client: *Client, response: term.Event.TerminalResponse) !?client_model.HostCommit {
    const color: ?negotiation.Color = switch (response) {
        .foreground_color => .foreground,
        .background_color => .background,
        else => null,
    };
    if (color) |target| {
        if (!client.host_negotiation.accept(target, client_clock.monotonic(client.io))) {
            return null;
        }
    }

    if (response == .kitty_graphics and response.kitty_graphics.image_id == kitty.zlib_query_image_id) {
        client.host_negotiation.zlib_support = if (response.kitty_graphics.supported) .supported else .unsupported;
        @import("../../../graphics/root.zig").kitty.delivery.setHostZlib(&client.graphics_store, response.kitty_graphics.supported);
        return null;
    }

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

    const capabilities = negotiation.settledCapabilities(client.model.hostCapabilities());

    if (client.host_negotiation.zlib_support == .unknown) {
        client.host_negotiation.zlib_support = .unsupported;
    }

    return use_case.reconcile(capabilities);
}

fn handler(client: *Client) host_capability.Handler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverResources,
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

fn support(supported: bool) client_model.HostCapabilitySupport {
    return if (supported) .supported else .unsupported;
}

fn deliverResources(raw_context: *anyopaque, commit: client_model.HostCommit) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try host_resources.deliver(client, commit);
}

test "Kitty probe replies translate by reserved image identity" {
    try std.testing.expectEqual(
        client_model.HostCapabilityObservation{ .images = .supported },
        translate(.{ .kitty_graphics = .{
            .image_id = kitty.query_image_id,
            .supported = true,
        } }).?,
    );
    try std.testing.expect(translate(.{ .kitty_graphics = .{
        .image_id = kitty.zlib_query_image_id,
        .supported = false,
    } }) == null);
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
        client_model.HostCapabilityObservation{ .pointer_pixels = .supported },
        translate(.{ .mouse_pixels = .{ .supported = true } }).?,
    );
    try std.testing.expect(translate(.primary_device_attributes) == null);
}
