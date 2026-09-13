//! The sole GUI consumer routes completions to the shared command controllers.
const core = @import("telar-core");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const Loop = @import("../NativeLoop.zig");
const Message = @import("../gui_event.zig").Message;

/// Drains one bounded turn, then folds reconnectable layout state once.
/// Example: `const status = try events.drain(loop, gui);`
pub fn drain(loop: *Loop, gui: *GuiClient) !?u8 {
    var turn = try loop.inbox.begin();
    defer loop.inbox.end();
    while (try loop.inbox.next(&turn)) |event| {
        const path = core.enter(pathFor(event));
        defer path.restore();
        if (try dispatch(gui, event)) |status| {
            return status;
        }
    }

    if (turn.processed != 0) {
        try client.client_layouts.observe(&gui.app);
    }

    try loop.configuration.poll(&gui.app);
    return null;
}

fn dispatch(gui: *GuiClient, event: Message) !?u8 {
    switch (event) {
        .server => |result| return gui.receive(result),
        .sent => |result| try client.runtime_io.handleSent(&gui.app, result),
        .input_ready => try gui.inputReady(),
        .focus => |focused| try gui.focus(focused),
        .presented => |result| try gui.complete(result.token, result.delivered),
        .configuration_ready => try gui.driver.configuration.accept(&gui.app),
        .input_timeout => |result| try result,
        .binding_timeout => |result| try gui.input.expire(&gui.app, result),
        .sidebar_animation_tick => |result| _ = try client.controllers.sidebar_animations.handleTick(&gui.app, result),
        .notification_tick => |result| _ = try client.controllers.notifications.handleTick(&gui.app, result),
        .bar_tick => |result| try client.controllers.bar_updates.handleTick(&gui.app, result),
        .bar_command => |result| try client.controllers.bar_updates.completeCommand(&gui.app, result),
        .plugin_result => |result| {
            if (try client.controllers.plugin_actions.complete(&gui.app, result)) {
                return 0;
            }
        },
    }

    return if (gui.input.stopped) @as(u8, 0) else null;
}

fn pathFor(event: Message) core.Path {
    return switch (event) {
        .configuration_ready, .notification_tick, .bar_tick, .bar_command, .plugin_result => .observation,
        else => .interactive,
    };
}
