//! Adapts user pane input to the client outbox and diagnostics.

const Client = @import("../../Client.zig");
const PaneInputCommand = @import("telar-client").PaneInputCommand;
const DeliveryType = @import("telar-client").PaneInputDelivery;
const now_module = @import("telar-core").now;
const PaneInputTargetType = @import("telar-client").PaneInputTarget;
const KeyType = @import("telar-client").Key;
const PanePasteSessionType = @import("telar-client").PanePasteSession;
const BoundaryType = @import("telar-client").Boundary;
const PaneInputHandlerType = @import("telar-client").PaneInputHandler;
const pane_viewports = @import("../panes/pane_viewports.zig");
const PaneInputEffectType = @import("telar-client").PaneInputEffect;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;

/// Delivers one user-input command through the application boundary.
///
/// ```zig
/// _ = try send(client, command);
/// ```
pub fn send(client: *Client, command: PaneInputCommand) !?DeliveryType {
    const started = now_module(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.execute(command));
}

/// Delivers one synthetic key sequence in a single pane-input transaction.
///
/// ```zig
/// _ = try sendKeys(client, .{ .pane = pane_id }, keys);
/// ```
pub fn sendKeys(client: *Client, target: PaneInputTargetType, keys: []const KeyType) !?DeliveryType {
    const started = now_module(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.executeKeys(target, keys));
}

/// Encodes one Lua paste decision against the current child modes.
///
/// ```zig
/// _ = try expressionPaste(client, "text");
/// ```
pub fn expressionPaste(client: *Client, text: []const u8) !?DeliveryType {
    const started = now_module(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.executePaste(.focused, text));
}

/// Delivers one history command, with execution outside bracketed paste framing.
/// Example: `_ = try historyPaste(client, .{ .text = command, .run = false });`.
pub fn historyPaste(client: *Client, request: struct { text: []const u8, run: bool }) !?DeliveryType {
    const started = now_module(client.io);
    var use_case = handler(client);

    return record(client, started, try use_case.executeHistoryPaste(.{ .target = .focused, .text = request.text, .run = request.run }));
}

/// Delivers one explicit marker for an exact model-owned paste session.
///
/// ```zig
/// _ = try pasteMarker(client, session, .start);
/// ```
pub fn pasteMarker(client: *Client, session: PanePasteSessionType, boundary: BoundaryType) !?DeliveryType {
    const started = now_module(client.io);
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

fn handler(client: *Client) PaneInputHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .send = enqueue,
            .viewport = pane_viewports.effects(client),
        },
    };
}

fn enqueue(context: *anyopaque, effect: PaneInputEffectType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueueInput(client, effect.pane_id, effect.bytes);
}

fn record(client: *Client, started: u64, delivery: ?DeliveryType) ?DeliveryType {
    const completed = delivery orelse return null;
    if (comptime enabled_module) {
        if (completed.source != .mouse) {
            client.telemetry.metrics.input_events += 1;
            client.telemetry.metrics.input_bytes += completed.byte_count;
            client.telemetry.metrics.input_enqueue.observe(elapsed_module(started, now_module(client.io)));
        }
    }

    return completed;
}
