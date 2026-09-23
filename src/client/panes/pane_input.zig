//! Pane input: delivers keys, pastes and expression input to the focused pane.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const encoding_support = @import("../input/encoding_support.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_viewport = @import("pane_viewport.zig");
const Client = @import("../execution/Client.zig");

/// Delivers one user-input command through the application boundary.
/// Example: `_ = try pane_input.sendPaneInput(app, command);`
pub fn sendPaneInput(client: *Client, command: data.PaneInputCommand) !?data.PaneInputDelivery {
    const started = core.now(client.io);

    const plan = client.model.planPaneInput(command.target) orelse return null;
    var encoded: [32]u8 = undefined;
    const prepared: data.PreparedPaneInput = switch (command.payload) {
        .bytes => |value| .{
            .source = command.source,
            .bytes = value,
        },
        .key => |value| .{
            .source = command.source,
            .bytes = try encoding_support.encodeKey(
                &encoded,
                value,
                plan.input_modes,
            ),
            .restore_viewport = value.phase != .release,
            .empty_is_noop = true,
        },
    };
    if (prepared.bytes.len == 0 and prepared.empty_is_noop) {
        return null;
    }

    return recordPaneInput(client, started, try deliverPaneInput(client, plan, prepared));
}

/// Starts one pane-owned paste against the current focused target.
/// Example: `_ = try pane_input.startPanePaste(app);`
pub fn startPanePaste(client: *Client) !data.PanePasteOutcome {
    const session = client.model.beginPanePaste() orelse return .ignored;
    errdefer {
        const rolled_back = client.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    if (!try deliverPanePaste(
        client,
        .{
            .marker = .{
                .session = session,
                .boundary = .start,
            },
        },
    )) {
        const rolled_back = client.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
        return .unavailable;
    }

    return .applied;
}

/// Delivers one host paste chunk to the captured target.
/// Example: `_ = try pane_input.appendPanePaste(app, text);`
pub fn appendPanePaste(client: *Client, text: []const u8) !data.PanePasteOutcome {
    const session = client.model.pane_paste orelse return .ignored;
    const delivered = try deliverPanePaste(
        client,
        .{
            .content = .{
                .session = session,
                .text = text,
            },
        },
    );

    return if (delivered) .applied else .unavailable;
}

/// Finishes the current pane paste and releases its captured identity.
/// Example: `_ = try pane_input.finishPanePaste(app);`
pub fn finishPanePaste(client: *Client) !data.PanePasteOutcome {
    const session = client.model.pane_paste orelse return .ignored;
    defer {
        const finished = client.model.finishPanePaste(session);
        std.debug.assert(finished);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    const delivered = try deliverPanePaste(
        client,
        .{
            .marker = .{
                .session = session,
                .boundary = .finish,
            },
        },
    );

    return if (delivered) .applied else .unavailable;
}

/// Delivers one synthetic key sequence in a single pane-input transaction.
pub fn sendPaneKeys(client: *Client, target: data.PaneInputTarget, keys: []const data.Key) !?data.PaneInputDelivery {
    const started = core.now(client.io);

    if (keys.len == 0 or keys.len > data.input_limits.max_synthetic_keys) {
        return error.InvalidInputLength;
    }

    const plan = client.model.planPaneInput(target) orelse return null;
    var encoded: [data.input_limits.max_encoded_bytes]u8 = undefined;
    var len: usize = 0;
    for (keys) |key| {
        var key_bytes: [32]u8 = undefined;
        const bytes = try encoding_support.encodeKey(
            &key_bytes,
            key,
            plan.input_modes,
        );
        if (bytes.len > encoded.len - len) {
            return error.InvalidInputLength;
        }

        @memcpy(encoded[len..][0..bytes.len], bytes);
        len += bytes.len;
    }

    return recordPaneInput(client, started, try deliverPaneInput(
        client,
        plan,
        .{
            .source = .host,
            .bytes = encoded[0..len],
        },
    ));
}

/// Encodes one Lua paste decision against the current child modes.
pub fn pasteExpression(client: *Client, text: []const u8) !?data.PaneInputDelivery {
    const started = core.now(client.io);

    const plan = client.model.planPaneInput(.focused) orelse return null;
    const framing_bytes: usize = if (plan.input_modes.bracketed_paste) 12 else 0;
    if (text.len > data.input_limits.max_encoded_bytes - framing_bytes) {
        return error.InvalidInputLength;
    }

    var encoded: [data.input_limits.max_encoded_bytes]u8 = undefined;
    const bytes = try encoding_support.encodePaste(
        &encoded,
        text,
        plan.input_modes,
    );

    return recordPaneInput(client, started, try deliverPaneInput(
        client,
        plan,
        .{
            .source = .paste,
            .bytes = bytes,
        },
    ));
}

/// Delivers one explicit marker for an exact model-owned paste session.
fn sendPasteMarker(client: *Client, session: data.PanePasteSession, boundary: data.PanePasteBoundary) !?data.PaneInputDelivery {
    const started = core.now(client.io);

    const plan = client.model.planPaneInput(
        .{
            .paste_session = session,
        },
    ) orelse return null;

    const bytes = switch (boundary) {
        .start => "\x1b[200~",
        .finish => "\x1b[201~",
    };

    return recordPaneInput(client, started, try deliverPaneInput(
        client,
        plan,
        .{
            .source = .paste,
            .bytes = bytes,
        },
    ));
}

pub fn recordPaneInput(client: *Client, started: u64, delivery: ?data.PaneInputDelivery) ?data.PaneInputDelivery {
    const completed = delivery orelse return null;

    if (completed.byte_count != 0) {
        client.model.to_host.pane_input = .{
            .pane_id = completed.pane_id,
            .at_ns = core.monotonic(client.io),
        };
    }

    if (comptime core.enabled) {
        if (completed.source != .mouse) {
            client.telemetry.metrics.input_events += 1;
            client.telemetry.metrics.input_bytes += completed.byte_count;
            client.telemetry.metrics.input_enqueue.observe(core.elapsed(started, core.now(client.io)));
        }
    }

    return completed;
}

pub fn deliverPaneInput(client: *Client, plan: data.PaneInputPlan, prepared: data.PreparedPaneInput) !data.PaneInputDelivery {
    if (prepared.bytes.len == 0 or prepared.bytes.len > prepared.limit) {
        return error.InvalidInputLength;
    }

    if (prepared.source != .mouse) {
        _ = client.model.clearPointerSelection();
    }

    if (prepared.source != .mouse and prepared.restore_viewport) {
        _ = try pane_viewport.applyPaneViewport(
            client,
            .{
                .pane_id = plan.pane_id,
                .target = .bottom,
            },
        );
    }

    try runtime_io.sendRuntimeInput(
        &client.model,
        .{
            .pane_id = plan.pane_id,
            .bytes = prepared.bytes,
        },
    );

    return .{
        .pane_id = plan.pane_id,
        .byte_count = prepared.bytes.len,
        .source = prepared.source,
    };
}

fn deliverPanePaste(client: *Client, delivery: data.PanePasteDelivery) !bool {
    const result = switch (delivery) {
        .marker => |marker| try sendPasteMarker(client, marker.session, marker.boundary),
        .content => |content_delivery| try sendPaneInput(
            client,
            .{
                .target = .{
                    .paste_session = content_delivery.session,
                },
                .source = .paste,
                .payload = .{
                    .bytes = content_delivery.text,
                },
            },
        ),
    };

    return result != null;
}

/// Rejects terminal controls and unframed multiline text before history can send input.
/// Example: `try validateHistoryText(command, modes.bracketed_paste);`.
pub fn validateHistoryText(text: []const u8, bracketed_paste: bool) !void {
    if (text.len == 0 or text.len > core.max_history_command_bytes) {
        return error.InvalidInputLength;
    }

    const view = std.unicode.Utf8View.init(text) catch return error.UnsafeHistoryText;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n' or codepoint == '\t') {
            if (!bracketed_paste) {
                return error.UnframedHistoryText;
            }

            continue;
        }

        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) {
            return error.UnsafeHistoryText;
        }
    }
}

test "history paste cannot smuggle terminal keys or escape its bracketed boundary" {
    try validateHistoryText("echo café", false);
    try validateHistoryText("echo first\necho second", true);
    try std.testing.expectError(error.UnframedHistoryText, validateHistoryText("echo first\necho second", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x1b[201~\r", true));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo x\x03", false));
    try std.testing.expectError(error.UnsafeHistoryText, validateHistoryText("echo \xc2\x9b", true));
}
