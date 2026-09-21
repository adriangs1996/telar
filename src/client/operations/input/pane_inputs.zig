//! Adapts user pane input to the client outbox and diagnostics.

const Delivery = @import("../../application/input/PaneInputDelivery.zig");
const Prepared = @import("../../application/input/Prepared.zig");
const encoding_support = @import("../../input/encoding_support.zig");
const pane_input = @import("../../application/input/pane_input.zig");
const root = @import("../../input/input_namespace.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const PaneInputPlanType = @import("../../model/PaneInputPlan.zig");
const Client = @import("../../AttachedClient.zig");
const PaneInputCommand = @import("../../application/input/PaneInputCommand.zig");
const DeliveryType = @import("../../application/input/PaneInputDelivery.zig");
const now_module = @import("telar-core").now;
const PaneInputTargetType = @import("../../model/types.zig").PaneInputTarget;
const KeyType = @import("../../input/Key.zig");
const PanePasteSessionType = @import("../../model/PanePasteSession.zig");
const BoundaryType = @import("../../application/input/pane_paste.zig").Boundary;
const pane_viewports = @import("../panes/pane_viewports.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;
const monotonic = @import("telar-core").monotonic;

/// Delivers one user-input command through the application boundary.
///
/// ```zig
/// _ = try send(client, command);
/// ```
pub fn send(client: *Client, command: PaneInputCommand) !?DeliveryType {
    const started = now_module(client.io);

    const plan = client.model.planPaneInput(command.target) orelse return null;
    var encoded: [32]u8 = undefined;
    const prepared: Prepared = switch (command.payload) {
        .bytes => |value| .{ .source = command.source, .bytes = value },
        .key => |value| .{
            .source = command.source,
            .bytes = try encoding_support.encodeKey(&encoded, value, plan.input_modes),
            .restore_viewport = value.phase != .release,
            .empty_is_noop = true,
        },
    };
    if (prepared.bytes.len == 0 and prepared.empty_is_noop) {
        return null;
    }

    return record(client, started, try deliver(client, plan, prepared));
}

/// Delivers one synthetic key sequence in a single pane-input transaction.
///
/// ```zig
/// _ = try sendKeys(client, .{ .pane = pane_id }, keys);
/// ```
pub fn sendKeys(client: *Client, target: PaneInputTargetType, keys: []const KeyType) !?DeliveryType {
    const started = now_module(client.io);

    if (keys.len == 0 or keys.len > pane_input.max_keys) {
        return error.InvalidInputLength;
    }

    const plan = client.model.planPaneInput(target) orelse return null;
    var encoded: [root.max_encoded_bytes]u8 = undefined;
    var len: usize = 0;
    for (keys) |key| {
        var key_bytes: [32]u8 = undefined;
        const bytes = try encoding_support.encodeKey(&key_bytes, key, plan.input_modes);
        if (bytes.len > encoded.len - len) {
            return error.InvalidInputLength;
        }

        @memcpy(encoded[len..][0..bytes.len], bytes);
        len += bytes.len;
    }

    return record(client, started, try deliver(client, plan, .{ .source = .host, .bytes = encoded[0..len] }));
}

/// Encodes one Lua paste decision against the current child modes.
///
/// ```zig
/// _ = try expressionPaste(client, "text");
/// ```
pub fn expressionPaste(client: *Client, text: []const u8) !?DeliveryType {
    const started = now_module(client.io);

    const plan = client.model.planPaneInput(.focused) orelse return null;
    const framing_bytes: usize = if (plan.input_modes.bracketed_paste) 12 else 0;
    if (text.len > root.max_encoded_bytes - framing_bytes) {
        return error.InvalidInputLength;
    }

    var encoded: [root.max_encoded_bytes]u8 = undefined;
    const bytes = try encoding_support.encodePaste(&encoded, text, plan.input_modes);

    return record(client, started, try deliver(client, plan, .{
        .source = .paste,
        .bytes = bytes,
    }));
}

/// Delivers one history command, with execution outside bracketed paste framing.
/// Example: `_ = try historyPaste(client, .{ .text = command, .run = false });`.
pub fn historyPaste(client: *Client, request: struct { text: []const u8, run: bool }) !?DeliveryType {
    const started = now_module(client.io);

    const plan = client.model.planPaneInput(.focused) orelse return null;
    try pane_input.validateHistoryText(request.text, plan.input_modes.bracketed_paste);
    var encoded: [max_history_command_bytes_module + 13]u8 = undefined;
    const paste = try encoding_support.encodePaste(&encoded, request.text, plan.input_modes);
    var len = paste.len;
    if (request.run) {
        encoded[len] = '\r';
        len += 1;
    }

    return record(client, started, try deliver(client, plan, .{ .source = .paste, .bytes = encoded[0..len], .limit = encoded.len }));
}

/// Delivers one explicit marker for an exact model-owned paste session.
///
/// ```zig
/// _ = try pasteMarker(client, session, .start);
/// ```
pub fn pasteMarker(client: *Client, session: PanePasteSessionType, boundary: BoundaryType) !?DeliveryType {
    const started = now_module(client.io);

    const plan = client.model.planPaneInput(.{ .paste_session = session }) orelse return null;

    const bytes = switch (boundary) {
        .start => "\x1b[200~",
        .finish => "\x1b[201~",
    };

    return record(client, started, try deliver(client, plan, .{
        .source = .paste,
        .bytes = bytes,
    }));
}

fn record(client: *Client, started: u64, delivery: ?DeliveryType) ?DeliveryType {
    const completed = delivery orelse return null;

    if (completed.byte_count != 0 and client.presentation.note_pane_input_fn != null) {
        client.presentation.notePaneInput(completed.pane_id, monotonic(client.io));
    }

    if (comptime enabled_module) {
        if (completed.source != .mouse) {
            client.telemetry.metrics.input_events += 1;
            client.telemetry.metrics.input_bytes += completed.byte_count;
            client.telemetry.metrics.input_enqueue.observe(elapsed_module(started, now_module(client.io)));
        }
    }

    return completed;
}

fn deliver(client: *Client, plan: PaneInputPlanType, prepared: Prepared) !Delivery {
    if (prepared.bytes.len == 0 or prepared.bytes.len > prepared.limit) {
        return error.InvalidInputLength;
    }

    if (prepared.source != .mouse) {
        _ = client.model.clearPointerSelection();
    }

    if (prepared.source != .mouse and prepared.restore_viewport) {
        _ = try pane_viewports.apply(client, .{ .pane_id = plan.pane_id, .target = .bottom });
    }

    try runtime_transport.enqueueInput(client, plan.pane_id, prepared.bytes);

    return .{
        .pane_id = plan.pane_id,
        .byte_count = prepared.bytes.len,
        .source = prepared.source,
    };
}
