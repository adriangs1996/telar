//! The TUI consumer classifies inbox messages and delegates each transition.
//! Presentation observes the latest committed state once per bounded turn.

const client_module = @import("telar-client");
const core = @import("telar-core");
const TerminalAdapter = @import("TerminalAdapter.zig");
const std = @import("std");
const EventResources = @import("EventResources.zig");
const client_startup = @import("session/client_startup.zig");
const presentation_lifecycle = @import("presentation/presentation_lifecycle.zig");
const host_inputs = @import("input/host_inputs.zig");
const host_capabilities = @import("host/host_capabilities.zig");
const host_resizes = @import("host/host_resizes.zig");
const kitty_delivery = @import("../graphics/kitty_delivery.zig");
const client_telemetry = @import("telemetry/telemetry.zig");
const host_effects = @import("host/host_effects.zig");
const view_chrome = @import("presentation/view_chrome.zig");

const EventTag = std.meta.Tag(TerminalAdapter.ClientEvent);

pub const Outcome = union(enum) {
    keep_running,
    exit: u8,
};

/// Handles one completed event as an indivisible client-loop iteration.
/// Terminal outcomes skip presentation observation because no next frame can
/// be delivered by this client.
///
/// ```zig
/// const outcome = try handle(terminal, event, resources);
/// ```
pub fn handle(terminal: *TerminalAdapter, event: TerminalAdapter.ClientEvent, resources: EventResources) !Outcome {
    const outcome = try dispatch(terminal, event, resources);
    if (outcome == .keep_running) {
        try observe(terminal);
    }

    return outcome;
}

/// Consumes only this turn's admitted work, then derives one presentation.
/// Example: `const outcome = try events.update(terminal, resources);`
pub fn update(terminal: *TerminalAdapter, resources: EventResources) !Outcome {
    const inbox = &terminal.inbox;
    var turn = try inbox.begin();
    defer inbox.end();
    while (try inbox.next(&turn)) |event| {
        const outcome = try dispatch(terminal, event, resources);
        if (outcome == .exit) {
            return outcome;
        }
    }

    if (turn.processed != 0) {
        try observe(terminal);
    }

    return .keep_running;
}

fn observe(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    const path = core.enter(.interactive);
    defer path.restore();
    try client_module.client_layout.synchronizeClientLayout(&client.model);
    try presentation_lifecycle.observe(terminal);
    try presentation_lifecycle.pumpOutput(terminal);
    try host_effects.deliver(terminal);
}

/// Routes one event, then draws the chrome facts it changed and delivers the
/// host requests it left, even when the event ends the client.
fn dispatch(terminal: *TerminalAdapter, event: TerminalAdapter.ClientEvent, resources: EventResources) !Outcome {
    const outcome = try route(terminal, event, resources);
    try view_chrome.refresh(terminal);
    try host_effects.deliver(terminal);

    return outcome;
}

fn route(terminal: *TerminalAdapter, event: TerminalAdapter.ClientEvent, resources: EventResources) !Outcome {
    const client = &terminal.app;

    const path = core.enter(pathFor(@as(EventTag, event)));
    defer path.restore();

    switch (event) {
        .input => |result| {
            if (try host_inputs.handleOwnedRead(terminal, result)) {
                return .{ .exit = 0 };
            }
        },
        .input_timeout => |result| {
            if (try host_inputs.handleInputTimeout(terminal, result)) {
                return .{ .exit = 0 };
            }
        },
        .binding_timeout => |result| {
            if (try host_inputs.handleBindingTimeout(terminal, result)) {
                return .{ .exit = 0 };
            }
        },
        .capability_timeout => |result| _ = try host_capabilities.handleExpiry(terminal, result),
        .resized => |result| _ = try host_resizes.handle(terminal, result, .{
            .tty = resources.tty,
            .watcher = resources.resize_watcher,
        }),
        .client => |message| {
            if (try client.update(message)) |status| {
                return .{ .exit = status };
            }
        },
        .draw => |result| try presentation_lifecycle.handleDraw(terminal, result),
        .media_tick => |result| try presentation_lifecycle.handleMediaTick(terminal, result),
        .host_written => |result| try presentation_lifecycle.handleWritten(terminal, result),
        .compression_done => |job| {
            kitty_delivery.completeCompression(&terminal.graphics_store, job);
            try terminal.presenter.requestMedia();
        },
        .telemetry_tick => |result| client_telemetry.handleTick(terminal, result, resources.heap.snapshot()),
        .telemetry_written => |result| client_telemetry.handleWritten(terminal, result),
        .clipboard_image => |result| try client_module.clipboard_capture.completeClipboardCapture(client, result),
    }

    if (try client_startup.advance(terminal)) {
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
        .telemetry_tick,
        .telemetry_written,
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
        .telemetry_tick,
        .telemetry_written,
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
