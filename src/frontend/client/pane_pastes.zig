//! Adapts one model-owned pane paste to the existing pane-input boundary.

const input_application = @import("application/input/root.zig");
const pane_inputs = @import("pane_inputs.zig");

const Client = @import("client.zig");
const pane_paste = input_application.pane_paste;

pub const Outcome = pane_paste.Outcome;

/// Starts one pane-owned paste against the current focused target.
///
/// ```zig
/// _ = try start(client);
/// ```
pub fn start(client: *Client) !Outcome {
    var use_case = handler(client);

    return use_case.start();
}

/// Delivers one host paste chunk to the captured target.
///
/// ```zig
/// _ = try content(client, bytes);
/// ```
pub fn content(client: *Client, text: []const u8) !Outcome {
    var use_case = handler(client);

    return use_case.content(text);
}

/// Finishes the current pane paste and releases its captured identity.
///
/// ```zig
/// _ = try finish(client);
/// ```
pub fn finish(client: *Client) !Outcome {
    var use_case = handler(client);

    return use_case.finish();
}

fn handler(client: *Client) pane_paste.PanePasteHandler {
    return .{
        .model = &client.model,
        .effects = effects(client),
    };
}

/// Returns the pane-paste delivery port reused by compound application flows.
///
/// ```zig
/// const paste_effects = effects(client);
/// ```
pub fn effects(client: *Client) pane_paste.Effects {
    return .{
        .context = client,
        .deliver = deliver,
    };
}

fn deliver(raw_context: *anyopaque, delivery: pane_paste.Delivery) !bool {
    const client: *Client = @ptrCast(@alignCast(raw_context));
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
