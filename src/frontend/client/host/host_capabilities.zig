//! Adapts terminal protocol replies and probe expiry to client host state.
const console = @import("console");

const pacing = @import("pacing");
const client_module = @import("telar-client");
const data = @import("model");
const TerminalAdapter = @import("../TerminalAdapter.zig");
const capabilities_module = @import("../../graphics/capabilities.zig");
const negotiation = @import("host_negotiation.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const std = @import("std");

/// Starts the exterior-terminal probes through one owner.
/// Example: `try begin(terminal);`.
pub fn begin(terminal: *TerminalAdapter) !void {
    try terminal.writer.writeAll(capabilities_module.query);
    try queryColors(terminal);
    try terminal.writer.flush();
}

/// Coalesces overlapping color probes. A resize needs no protocol details.
/// Example: `try refresh(terminal);`.
pub fn refresh(terminal: *TerminalAdapter) !void {
    try terminal.writer.writeAll(negotiation.pixel_query);
    try queryColors(terminal);
    try terminal.writer.flush();
}

fn queryColors(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    if (!terminal.host_negotiation.begin(pacing.clock.monotonic(client.io))) {
        return;
    }

    try terminal.writer.writeAll(negotiation.color_query);
    try scheduleExpiry(terminal);
}

/// Example: `try scheduleExpiry(terminal);`.
pub fn scheduleExpiry(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    const state = &terminal.host_negotiation;
    switch (state.timer.update(client.io, state.deadline_ns)) {
        .idle, .retained => {},
        .schedule => terminal.inbox.start(.capability_timeout, .{ pacing.deadline_timer.wait, .{
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
/// _ = try handleExpiry(terminal, result);
/// ```
pub fn handleExpiry(terminal: *TerminalAdapter, result: anyerror!void) !?data.HostCommit {
    const client = &terminal.app;

    try terminal.host_negotiation.timer.complete(result);
    if (!terminal.host_negotiation.expire(pacing.clock.monotonic(client.io))) {
        try scheduleExpiry(terminal);
        return null;
    }

    return expire(terminal);
}

/// Commits one recognized terminal response and projects changed resources.
///
/// ```zig
/// _ = try observe(terminal, response);
/// ```
pub fn observe(terminal: *TerminalAdapter, response: console.Event.TerminalResponse) !?data.HostCommit {
    const client = &terminal.app;

    const color: ?negotiation.Color = switch (response) {
        .foreground_color => .foreground,
        .background_color => .background,
        else => null,
    };
    if (color) |target| {
        if (!terminal.host_negotiation.accept(target, pacing.clock.monotonic(client.io))) {
            return null;
        }
    }

    if (response == .kitty_graphics and response.kitty_graphics.image_id == capabilities_module.zlib_query_image_id) {
        terminal.host_negotiation.zlib_support = if (response.kitty_graphics.supported) .supported else .unsupported;
        kitty_delivery.setHostZlib(&terminal.graphics_store, response.kitty_graphics.supported);
        return null;
    }

    const observation = translate(response) orelse return null;
    return client_module.host_capabilities.observeHostCapability(client, observation);
}

/// Settles unanswered probes and projects their fallback resources.
///
/// ```zig
/// _ = try expire(terminal);
/// ```
pub fn expire(terminal: *TerminalAdapter) !?data.HostCommit {
    const client = &terminal.app;

    const capabilities = negotiation.settledCapabilities(client.model.host.host_capabilities);

    if (terminal.host_negotiation.zlib_support == .unknown) {
        terminal.host_negotiation.zlib_support = .unsupported;
    }

    return client_module.host_capabilities.reconcileHostCapabilities(client, capabilities);
}

/// Translates one parser reply into a protocol-free host observation.
///
/// ```zig
/// const observation = translate(response) orelse return;
/// ```
pub fn translate(response: console.Event.TerminalResponse) ?data.HostCapabilityObservation {
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
