//! Routes one completed client event through its owning adapter, then
//! publishes the resulting presentation observation before the next event.

const std = @import("std");
const core = @import("telar-core");
const platform = @import("../../platform/root.zig");

const Client = @import("../client.zig");
const agent_sounds = @import("../agent_sounds.zig");
const client_telemetry = @import("../telemetry.zig");
const clipboard_images = @import("../clipboard_images.zig");
const config_reloads = @import("../config_reloads.zig");
const host_capabilities = @import("../host_capabilities.zig");
const host_inputs = @import("../host_inputs.zig");
const host_resizes = @import("../host_resizes.zig");
const notifications = @import("../notifications.zig");
const presentation_lifecycle = @import("../presentation_lifecycle.zig");
const plugin_actions = @import("../plugin_actions.zig");
const runtime_transport = @import("../runtime_transport.zig");
const sidebar_animations = @import("../sidebar_animations.zig");

const diagnostics = core.diagnostics;
const Event = Client.ClientEvent;
const EventTag = std.meta.Tag(Event);

pub const Resources = struct {
    tty: *const platform.Tty,
    resize_watcher: *platform.ResizeWatcher,
    heap: *const diagnostics.Heap,
};

pub const Outcome = union(enum) {
    keep_running,
    exit: u8,
};

/// Handles one completed event as an indivisible client-loop iteration.
/// Terminal outcomes skip presentation observation because no next frame can
/// be delivered by this client.
///
/// ```zig
/// const outcome = try handle(client, event, resources);
/// ```
pub fn handle(client: *Client, event: Event, resources: Resources) !Outcome {
    const path = diagnostics.enter(pathFor(@as(EventTag, event)));
    defer path.restore();

    switch (try route(client, event, resources)) {
        .keep_running => try presentation_lifecycle.observe(client),
        .exit => |status| return .{ .exit = status },
    }

    return .keep_running;
}

fn route(client: *Client, event: Event, resources: Resources) !Outcome {
    switch (event) {
        .input => |result| {
            if (try host_inputs.handleRead(client, result)) {
                return .{ .exit = 0 };
            }
        },
        .input_timeout => |result| {
            if (try host_inputs.handleInputTimeout(client, result)) {
                return .{ .exit = 0 };
            }
        },
        .binding_timeout => |result| {
            if (try host_inputs.handleBindingTimeout(client, result)) {
                return .{ .exit = 0 };
            }
        },
        .capability_timeout => |result| _ = try host_capabilities.handleExpiry(client, result),
        .resized => |result| _ = try host_resizes.handle(client, result, .{
            .tty = resources.tty,
            .watcher = resources.resize_watcher,
        }),
        .server => |result| {
            if (try runtime_transport.handleRead(client, result)) |status| {
                return .{ .exit = status };
            }
        },
        .sent => |result| try runtime_transport.handleSent(client, result),
        .draw => |result| try presentation_lifecycle.handleDraw(client, result),
        .media_tick => |result| try presentation_lifecycle.handleMediaTick(client, result),
        .sidebar_animation_tick => |result| _ = try sidebar_animations.handleTick(client, result),
        .notification_tick => |result| _ = try notifications.handleTick(client, result),
        .sound_played => |result| try agent_sounds.handlePlayed(client, result),
        .telemetry_tick => |result| client_telemetry.handleTick(client, result, resources.heap.snapshot()),
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        .config_reload => |result| _ = try config_reloads.handle(client, result),
        .plugin_result => |result| {
            if (try plugin_actions.complete(client, result)) {
                return .{ .exit = 0 };
            }
        },
        .clipboard_image => |result| try clipboard_images.complete(client, result),
    }

    return .keep_running;
}

fn pathFor(tag: EventTag) diagnostics.Path {
    return switch (tag) {
        .input,
        .input_timeout,
        .binding_timeout,
        .capability_timeout,
        .resized,
        .server,
        .sent,
        .draw,
        .sidebar_animation_tick,
        => .interactive,
        .media_tick, .clipboard_image => .media,
        .notification_tick,
        .sound_played,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
        .plugin_result,
        => .observation,
    };
}

test "client event paths preserve interactive media and observation budgets" {
    const interactive = [_]EventTag{
        .input,
        .input_timeout,
        .binding_timeout,
        .capability_timeout,
        .resized,
        .server,
        .sent,
        .draw,
        .sidebar_animation_tick,
    };
    const media = [_]EventTag{ .media_tick, .clipboard_image };
    const observation = [_]EventTag{
        .notification_tick,
        .sound_played,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
        .plugin_result,
    };

    for (interactive) |tag| {
        try std.testing.expectEqual(diagnostics.Path.interactive, pathFor(tag));
    }
    for (media) |tag| {
        try std.testing.expectEqual(diagnostics.Path.media, pathFor(tag));
    }
    for (observation) |tag| {
        try std.testing.expectEqual(diagnostics.Path.observation, pathFor(tag));
    }
}
