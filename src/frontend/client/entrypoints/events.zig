//! Routes one completed client event through its owning adapter, then
//! publishes the resulting presentation observation before the next event.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const std = @import("std");
const Client = @import("telar-client").AttachedClient;
const Resources = @import("Resources.zig");
const enter_module = @import("telar-core").enter;
const client_startup = @import("../controllers/session/client_startup.zig");
const client_layouts = @import("telar-client").client_layouts;
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const runtime_transport = @import("telar-client").runtime_io;
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const sidebar_animations = @import("telar-client").controllers.sidebar_animations;
const notifications = @import("telar-client").controllers.notifications;
const bar_updates = @import("telar-client").controllers.bar_updates;
const agent_sounds = @import("telar-client").controllers.agent_sounds;
const client_telemetry = @import("../resources/telemetry.zig");
const config_reloads = @import("telar-client").controllers.config_reloads;
const plugin_actions = @import("telar-client").controllers.plugin_actions;
const clipboard_images = @import("telar-client").controllers.clipboard_images;
const link_openings = @import("telar-client").controllers.link_openings;
const PathType = @import("telar-core").Path;

const EventTag = std.meta.Tag(TerminalClient.ClientEvent);

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
pub fn handle(client: *Client, event: TerminalClient.ClientEvent, resources: Resources) !Outcome {
    const path = enter_module(pathFor(@as(EventTag, event)));
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

fn route(client: *Client, event: TerminalClient.ClientEvent, resources: Resources) !Outcome {
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
            kitty_delivery.completeCompression(&host(client).graphics_store, job);
            try host(client).presenter.requestMedia();
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

fn pathFor(tag: EventTag) PathType {
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
        try std.testing.expectEqual(PathType.interactive, pathFor(tag));
    }
    for (media) |tag| {
        try std.testing.expectEqual(PathType.media, pathFor(tag));
    }
    for (observation) |tag| {
        try std.testing.expectEqual(PathType.observation, pathFor(tag));
    }
}
