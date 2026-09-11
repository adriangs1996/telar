//! Routes one completed client event through its owning adapter, then
//! publishes the resulting presentation observation before the next event.

const std = @import("std");
const core = @import("telar-core");
const platform = @import("../../platform/root.zig");

const Client = @import("../Client.zig");
const agent_sounds = @import("../controllers/agents/agent_sounds.zig");
const client_telemetry = @import("../resources/telemetry.zig");
const client_layouts = @import("../resources/client_layouts.zig");
const client_startup = @import("../controllers/session/client_startup.zig");
const clipboard_images = @import("../controllers/host/clipboard_images.zig");
const bar_updates = @import("../controllers/configuration/bar_updates.zig");
const config_reloads = @import("../controllers/configuration/config_reloads.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const link_openings = @import("../controllers/input/link_openings.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const notifications = @import("../controllers/notifications/notifications.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const plugin_actions = @import("../controllers/configuration/plugin_actions.zig");
const runtime_transport = @import("runtime_io.zig");
const sidebar_animations = @import("../controllers/notifications/sidebar_animations.zig");

pub const diagnostics = core.diagnostics;
const Event = Client.ClientEvent;
const EventTag = std.meta.Tag(Event);

pub const Resources = @import("Resources.zig");

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
        .keep_running => {
            if (try client_startup.advance(client)) {
                return .{ .exit = 0 };
            }

            try client_layouts.observe(client);
            try presentation_lifecycle.observe(client);
            try presentation_lifecycle.pumpOutput(client);
        },
        .exit => |status| return .{ .exit = status },
    }

    return .keep_running;
}

fn route(client: *Client, event: Event, resources: Resources) !Outcome {
    switch (event) {
        .input => |result| {
            if (try host_inputs.handleOwnedRead(client, result)) {
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
        .host_written => |result| try presentation_lifecycle.handleWritten(client, result),
        .compression_done => |job| {
            @import("../../graphics/root.zig").kitty.delivery.completeCompression(&client.graphics_store, job);
            try client.presenter.requestMedia();
        },
        .sidebar_animation_tick => |result| _ = try sidebar_animations.handleTick(client, result),
        .notification_tick => |result| _ = try notifications.handleTick(client, result),
        .bar_tick => |result| try bar_updates.handleTick(client, result),
        .bar_command => |completion| try bar_updates.completeCommand(client, completion),
        .sound_played => |result| try agent_sounds.handlePlayed(client, result),
        .notified => |result| _ = result catch {},
        .telemetry_tick => |result| client_telemetry.handleTick(client, result, resources.heap.snapshot()),
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        .config_reload => |result| _ = try config_reloads.handle(client, result),
        .plugin_result => |result| {
            if (try plugin_actions.complete(client, result)) {
                return .{ .exit = 0 };
            }
        },
        .clipboard_image => |result| try clipboard_images.complete(client, result),
        .link_opened => |result| try link_openings.complete(client, result),
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
        .host_written => .interactive,
        .media_tick, .clipboard_image, .compression_done => .media,
        .notification_tick,
        .bar_tick,
        .bar_command,
        .sound_played,
        .notified,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
        .plugin_result,
        .link_opened,
        => .observation,
    };
}

test "client event paths preserve interactive media and observation budgets" {
    const interactive = [_]EventTag{
        .host_written,
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
    const media = [_]EventTag{ .media_tick, .clipboard_image, .compression_done };
    const observation = [_]EventTag{
        .notification_tick,
        .bar_tick,
        .bar_command,
        .sound_played,
        .notified,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
        .plugin_result,
        .link_opened,
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
