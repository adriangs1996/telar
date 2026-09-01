//! Adapts user pane input to the client outbox and diagnostics.

const core = @import("telar-core");
const input_application = @import("application/input/root.zig");
const pane_viewports = @import("pane_viewports.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const diagnostics = core.diagnostics;
const pane_input = input_application.pane_input;
const pane_paste = input_application.pane_paste;
const runtime_transport = @import("runtime_transport.zig");

/// Delivers one user-input command through the application boundary.
///
/// ```zig
/// _ = try send(client, command);
/// ```
pub fn send(client: *Client, command: pane_input.Command) !?pane_input.Delivery {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.execute(command));
}

/// Encodes one Lua paste decision against the current child modes.
///
/// ```zig
/// _ = try expressionPaste(client, "text");
/// ```
pub fn expressionPaste(client: *Client, text: []const u8) !?pane_input.Delivery {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.executePaste(.focused, text));
}

/// Delivers one explicit marker for an exact model-owned paste session.
///
/// ```zig
/// _ = try pasteMarker(client, session, .start);
/// ```
pub fn pasteMarker(client: *Client, session: client_model.PanePasteSession, boundary: pane_paste.Boundary) !?pane_input.Delivery {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);
    const delivery = try use_case.executePasteMarker(.{
        .target = .{ .paste_session = session },
        .marker = switch (boundary) {
            .start => .start,
            .finish => .finish,
        },
    });

    return record(client, started, delivery);
}

fn handler(client: *Client) pane_input.PaneInputHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .send = enqueue,
            .viewport = pane_viewports.effects(client),
        },
    };
}

fn enqueue(context: *anyopaque, effect: pane_input.PaneInputEffect) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueueInput(client, effect.pane_id, effect.bytes);
}

fn record(client: *Client, started: u64, delivery: ?pane_input.Delivery) ?pane_input.Delivery {
    const completed = delivery orelse return null;
    if (comptime diagnostics.enabled) {
        if (completed.source != .mouse) {
            client.telemetry.metrics.input_events += 1;
            client.telemetry.metrics.input_bytes += completed.byte_count;
            client.telemetry.metrics.input_enqueue.observe(diagnostics.elapsed(started, diagnostics.now(client.io)));
        }
    }

    return completed;
}
