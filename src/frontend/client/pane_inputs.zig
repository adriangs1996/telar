//! Adapts user pane input to the client outbox and diagnostics.

const core = @import("telar-core");
const client_application = @import("application/root.zig");
const pane_viewports = @import("pane_viewports.zig");

const Client = @import("client.zig");
const diagnostics = core.diagnostics;
const pane_input = client_application.pane_input;
const schema = core.schema;

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

/// Captures the focused pane for a streamed host paste and emits its opening
/// marker when the child's bracketed-paste mode requires one.
///
/// ```zig
/// const pane_id = try beginPaste(client) orelse return;
/// ```
pub fn beginPaste(client: *Client) !?schema.PaneId {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);
    const outcome = try use_case.executePasteBoundary(.{
        .target = .focused,
        .boundary = .start,
    }) orelse return null;
    _ = record(client, started, outcome.delivery);

    return outcome.pane_id;
}

/// Delivers one streamed paste chunk to the pane captured at paste start.
///
/// ```zig
/// _ = try continuePaste(client, pane_id, text);
/// ```
pub fn continuePaste(client: *Client, pane_id: schema.PaneId, text: []const u8) !?pane_input.Delivery {
    return send(client, .{
        .target = .{ .pane = pane_id },
        .source = .paste,
        .payload = .{ .bytes = text },
    });
}

/// Emits the closing marker for a still-active bracketed paste target.
///
/// ```zig
/// _ = try endPaste(client, pane_id);
/// ```
pub fn endPaste(client: *Client, pane_id: schema.PaneId) !?pane_input.Delivery {
    const started = diagnostics.now(client.io);
    var use_case = handler(client);
    const outcome = try use_case.executePasteBoundary(.{
        .target = .{ .pane = pane_id },
        .boundary = .end,
    }) orelse return null;

    return record(client, started, outcome.delivery);
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

    try client.enqueueInput(effect.pane_id, effect.bytes);
}

fn record(client: *Client, started: u64, delivery: ?pane_input.Delivery) ?pane_input.Delivery {
    const completed = delivery orelse return null;
    if (comptime diagnostics.enabled) {
        if (completed.source != .mouse) {
            client.metrics.input_events += 1;
            client.metrics.input_bytes += completed.byte_count;
            client.metrics.input_enqueue.observe(diagnostics.elapsed(started, diagnostics.now(client.io)));
        }
    }

    return completed;
}
