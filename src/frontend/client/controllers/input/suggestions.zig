//! Adapts the command-suggestion palette between the name prompt, the
//! runtime connection and the client model: Enter asks the runtime's engine
//! once, only the awaited reply lands, and Enter on a landed suggestion
//! pastes it into the focused pane without running it.

const core = @import("telar-core");
const suggestion = @import("../../model/suggestion.zig");
const name_prompts = @import("name_prompts.zig");
const pane_inputs = @import("pane_inputs.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const connection_outbox = @import("../../connection/outbox.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const Client = @import("../../client.zig");
const schema = core.schema;

/// Opens the palette with an empty request and no suggestion.
///
/// ```zig
/// _ = try begin(client);
/// ```
pub fn begin(client: *Client) !bool {
    if (!name_prompts.beginSuggestPalette(client)) {
        return false;
    }

    client.model.suggestion.begin();
    return true;
}

/// Sends one bounded request for the focused pane and awaits only its
/// reply. Without a focused pane there is nothing to give context, so the
/// palette shows a failure instead of asking.
///
/// ```zig
/// try request(client, prompt.field.text());
/// ```
pub fn request(client: *Client, text: []const u8) !void {
    const pane_id = focusedPane(client) orelse {
        client.model.suggestion.expect(1);
        _ = client.model.suggestion.apply(1, .failed, "");
        return;
    };

    const request_id = try request_lifecycle.nextId(client);
    var owned: connection_outbox.OwnedSuggestion = .{
        .request_id = request_id,
        .pane_id = pane_id,
        .text_len = @intCast(@min(text.len, connection_outbox.OwnedSuggestion.max_text_bytes)),
    };
    @memcpy(owned.text[0..owned.text_len], text[0..owned.text_len]);

    client.model.suggestion.expect(schema.id.raw(request_id));
    try runtime_transport.enqueue(client, .{ .suggest_command = owned });
}

/// Lands one runtime reply. Stale replies and replies arriving after the
/// palette closed change nothing visible.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: schema.CommandSuggestion) !bool {
    return client.model.suggestion.apply(schema.id.raw(message.request_id), message.status, message.text);
}

/// Pastes the landed suggestion into the focused pane. Runs after the
/// prompt closed, because `planPaneInput(.focused)` refuses input while a
/// prompt is active. Nothing is pasted unless a suggestion is ready.
///
/// ```zig
/// try pasteSuggestion(client);
/// ```
pub fn pasteSuggestion(client: *Client) !void {
    const state = &client.model.suggestion;
    if (state.phase != .ready) {
        return;
    }

    _ = try pane_inputs.expressionPaste(client, state.textSlice());
}

fn focusedPane(client: *Client) ?schema.PaneId {
    const active = client.model.workspace.activeConst() orelse return null;
    const pane = active.model.focusedPaneConst() orelse return null;
    return pane.id;
}
