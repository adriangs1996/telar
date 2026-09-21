//! Adapts one model-owned pane paste to the existing pane-input boundary.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const ApplicationInputPanePasteOutcome = @import("../../application/input/pane_paste.zig").Outcome;
const ApplicationInputPanePasteDelivery = @import("../../application/input/pane_paste.zig").Delivery;
const pane_inputs = @import("pane_inputs.zig");

/// Starts one pane-owned paste against the current focused target.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !ApplicationInputPanePasteOutcome {
    const session = client.model.beginPanePaste() orelse return .ignored;
    errdefer {
        const rolled_back = client.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    if (!try deliver(client, .{ .marker = .{
        .session = session,
        .boundary = .start,
    } })) {
        const rolled_back = client.model.finishPanePaste(session);
        std.debug.assert(rolled_back);
        return .unavailable;
    }

    return .applied;
}

/// Delivers one host paste chunk to the captured target.
///
/// ```zig
/// _ = try content(client, bytes);
/// ```
pub fn content(client: *Client, text: []const u8) !ApplicationInputPanePasteOutcome {
    const session = client.model.panePasteSession() orelse return .ignored;
    const delivered = try deliver(client, .{ .content = .{
        .session = session,
        .text = text,
    } });

    return if (delivered) .applied else .unavailable;
}

/// Finishes the current pane paste and releases its captured identity.
///
/// ```zig
/// _ = try finish(client);
/// ```
pub fn finish(client: *Client) !ApplicationInputPanePasteOutcome {
    const session = client.model.panePasteSession() orelse return .ignored;
    defer {
        const finished = client.model.finishPanePaste(session);
        std.debug.assert(finished);
    }

    if (!session.bracketed_paste) {
        return .applied;
    }

    const delivered = try deliver(client, .{ .marker = .{
        .session = session,
        .boundary = .finish,
    } });

    return if (delivered) .applied else .unavailable;
}

fn deliver(client: *Client, delivery: ApplicationInputPanePasteDelivery) !bool {
    const result = switch (delivery) {
        .marker => |marker| try pane_inputs.pasteMarker(
            client,
            marker.session,
            marker.boundary,
        ),
        .content => |content_delivery| try pane_inputs.send(client, .{
            .target = .{ .paste_session = content_delivery.session },
            .source = .paste,
            .payload = .{ .bytes = content_delivery.text },
        }),
    };

    return result != null;
}
