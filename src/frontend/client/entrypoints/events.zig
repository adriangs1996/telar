//! The TUI consumer classifies inbox messages and delegates each transition.
//! Presentation observes the latest committed state once per bounded turn.

const client_module = @import("telar-client");
const core = @import("telar-core");
const TerminalClient = @import("../TerminalClient.zig");
const std = @import("std");
const Resources = @import("Resources.zig");
const client_startup = @import("../controllers/session/client_startup.zig");
const presentation_lifecycle = @import("../presentation/presentation_lifecycle.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const host_capabilities = @import("../controllers/host/host_capabilities.zig");
const host_resizes = @import("../controllers/host/host_resizes.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const client_telemetry = @import("../resources/telemetry.zig");

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
pub fn handle(client: *client_module.AttachedClient, event: TerminalClient.ClientEvent, resources: Resources) !Outcome {
    const outcome = try dispatch(client, event, resources);
    if (outcome == .keep_running) {
        try observe(client);
    }

    return outcome;
}

/// Consumes only this turn's admitted work, then derives one presentation.
/// Example: `const outcome = try events.update(client, resources);`
pub fn update(client: *client_module.AttachedClient, resources: Resources) !Outcome {
    const inbox = &TerminalClient.of(client).inbox;
    var turn = try inbox.begin();
    defer inbox.end();
    while (try inbox.next(&turn)) |event| {
        const outcome = try dispatch(client, event, resources);
        if (outcome == .exit) {
            return outcome;
        }
    }

    if (turn.processed != 0) {
        try observe(client);
    }

    return .keep_running;
}

fn observe(client: *client_module.AttachedClient) !void {
    const path = core.enter(.interactive);
    defer path.restore();
    try client.synchronizeClientLayout();
    try presentation_lifecycle.observe(client);
    try presentation_lifecycle.pumpOutput(client);
}

fn dispatch(client: *client_module.AttachedClient, event: TerminalClient.ClientEvent, resources: Resources) !Outcome {
    const path = core.enter(pathFor(@as(EventTag, event)));
    defer path.restore();

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
        .client => |message| {
            if (try client.update(message)) |status| {
                return .{ .exit = status };
            }
        },
        .draw => |result| try presentation_lifecycle.handleDraw(client, result),
        .media_tick => |result| try presentation_lifecycle.handleMediaTick(client, result),
        .host_written => |result| try presentation_lifecycle.handleWritten(client, result),
        .compression_done => |job| {
            kitty_delivery.completeCompression(&TerminalClient.of(client).graphics_store, job);
            try TerminalClient.of(client).presenter.requestMedia();
        },
        .sound_played => |result| try client.completeAgentSound(result),
        .notified => |result| _ = result catch {},
        .telemetry_tick => |result| client_telemetry.handleTick(client, result, resources.heap.snapshot()),
        .telemetry_written => |result| client_telemetry.handleWritten(client, result),
        .config_reload => |result| _ = try client.completeConfigReload(result),
        .clipboard_image => |result| try client.completeClipboardCapture(result),
    }

    if (try client_startup.advance(client)) {
        return .{ .exit = 0 };
    }

    return .keep_running;
}

fn pathFor(tag: EventTag) core.Path {
    return switch (tag) {
        .input,
        .input_timeout,
        .binding_timeout,
        .capability_timeout,
        .resized,
        .client,
        .draw,
        => .interactive,
        .host_written => .interactive,
        .media_tick, .clipboard_image, .compression_done => .media,
        .sound_played,
        .notified,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
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
        .client,
        .draw,
    };
    const media = [_]EventTag{ .media_tick, .clipboard_image, .compression_done };
    const observation = [_]EventTag{
        .sound_played,
        .notified,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
    };

    for (interactive) |tag| {
        try std.testing.expectEqual(core.Path.interactive, pathFor(tag));
    }
    for (media) |tag| {
        try std.testing.expectEqual(core.Path.media, pathFor(tag));
    }
    for (observation) |tag| {
        try std.testing.expectEqual(core.Path.observation, pathFor(tag));
    }
}
