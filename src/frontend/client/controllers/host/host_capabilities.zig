//! Adapts terminal protocol replies and probe expiry to client host state.

const Client = @import("../../Client.zig");
const capabilities_module = @import("../../../graphics/capabilities.zig");
const negotiation = @import("../../resources/host_negotiation.zig");
const monotonic_module = @import("telar-client").monotonic;
const wait_module = @import("telar-client").wait;
const HostCommitType = @import("telar-client").HostCommit;
const term = @import("../../../presentation/screen_support.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const HandlerType = @import("telar-client").HostCapabilitiesHandler;
const HostCapabilityObservationType = @import("telar-client").HostCapabilityObservation;
const HostCapabilitySupportType = @import("telar-client").HostCapabilitySupport;
const host_resources = @import("host_resources.zig");
const std = @import("std");

/// Starts the exterior-terminal probes through one owner.
/// Example: `try begin(client);`.
pub fn begin(client: *Client) !void {
    try client.writer.writeAll(capabilities_module.query);
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
    if (!client.host_negotiation.begin(monotonic_module(client.io))) {
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
        .schedule => client.select.concurrent(.capability_timeout, wait_module, .{
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
pub fn handleExpiry(client: *Client, result: anyerror!void) !?HostCommitType {
    try client.host_negotiation.timer.complete(result);
    if (!client.host_negotiation.expire(monotonic_module(client.io))) {
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
pub fn observe(client: *Client, response: term.Event.TerminalResponse) !?HostCommitType {
    const color: ?negotiation.Color = switch (response) {
        .foreground_color => .foreground,
        .background_color => .background,
        else => null,
    };
    if (color) |target| {
        if (!client.host_negotiation.accept(target, monotonic_module(client.io))) {
            return null;
        }
    }

    if (response == .kitty_graphics and response.kitty_graphics.image_id == capabilities_module.zlib_query_image_id) {
        client.host_negotiation.zlib_support = if (response.kitty_graphics.supported) .supported else .unsupported;
        kitty_delivery.setHostZlib(&client.graphics_store, response.kitty_graphics.supported);
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
pub fn expire(client: *Client) !?HostCommitType {
    var use_case = handler(client);

    const capabilities = negotiation.settledCapabilities(client.model.hostCapabilities());

    if (client.host_negotiation.zlib_support == .unknown) {
        client.host_negotiation.zlib_support = .unsupported;
    }

    return use_case.reconcile(capabilities);
}

fn handler(client: *Client) HandlerType {
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
pub fn translate(response: term.Event.TerminalResponse) ?HostCapabilityObservationType {
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

fn support(supported: bool) HostCapabilitySupportType {
    return if (supported) .supported else .unsupported;
}

fn deliverResources(raw_context: *anyopaque, commit: HostCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try host_resources.deliver(client, commit);
}

test "Kitty probe replies translate by reserved image identity" {
    try std.testing.expectEqual(
        HostCapabilityObservationType{ .images = .supported },
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
        HostCapabilityObservationType{ .window_pixels = .{
            .width = 1200,
            .height = 800,
        } },
        translate(.{ .window_pixels = .{ .width = 1200, .height = 800 } }).?,
    );
    try std.testing.expectEqual(
        HostCapabilityObservationType{ .cell_pixels = .{
            .width = 10,
            .height = 20,
        } },
        translate(.{ .cell_pixels = .{ .width = 10, .height = 20 } }).?,
    );
    try std.testing.expectEqual(
        HostCapabilityObservationType{ .pointer_pixels = .supported },
        translate(.{ .mouse_pixels = .{ .supported = true } }).?,
    );
    try std.testing.expect(translate(.primary_device_attributes) == null);
}
