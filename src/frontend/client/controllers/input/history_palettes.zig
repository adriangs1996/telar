//! Adapts the history palette between the name prompt, the runtime
//! connection and the client model: queries go out per keystroke, only the
//! newest reply lands, and Enter pastes the selected command.

const core = @import("telar-core");
const history_palette = @import("../../model/history_palette.zig");
const name_prompts = @import("name_prompts.zig");
const pane_inputs = @import("pane_inputs.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const connection_outbox = @import("../../connection/outbox.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const Client = @import("../../client.zig");
const schema = core.schema;

/// Opens the palette and requests the unfiltered newest history.
///
/// ```zig
/// _ = try begin(client);
/// ```
pub fn begin(client: *Client) !bool {
    if (!name_prompts.beginHistoryPalette(client)) {
        return false;
    }

    client.model.history_palette.begin();
    try sendQuery(client, "");
    return true;
}

/// Sends one bounded history query and awaits only its reply.
///
/// ```zig
/// try sendQuery(client, prompt.field.text());
/// ```
pub fn sendQuery(client: *Client, query: []const u8) !void {
    const request_id = try request_lifecycle.nextId(client);
    var owned: connection_outbox.OwnedHistoryQuery = .{
        .request_id = request_id,
        .query_len = @intCast(@min(query.len, connection_outbox.OwnedHistoryQuery.max_query_bytes)),
        .limit = history_palette.max_entries,
    };
    @memcpy(owned.query[0..owned.query_len], query[0..owned.query_len]);

    client.model.history_palette.expect(schema.id.raw(request_id));
    try runtime_transport.enqueue(client, .{ .query_history = owned });
}

/// Applies one runtime reply to the palette model. Stale replies and replies
/// arriving after the palette closed change nothing visible.
///
/// ```zig
/// _ = try apply(client, view);
/// ```
pub fn apply(client: *Client, view: schema.HistoryResultsView) !bool {
    var storage: [history_palette.max_entries]schema.HistoryEntry = undefined;
    var count: usize = 0;
    var iterator = view.entries();
    while (try iterator.next()) |entry| {
        if (count == storage.len) {
            break;
        }

        storage[count] = entry;
        count += 1;
    }

    return client.model.history_palette.apply(schema.id.raw(view.request_id), storage[0..count]);
}

/// Pastes the selected command into the focused pane. Called by the prompt
/// submit effect; an empty result list simply closes the palette.
///
/// ```zig
/// _ = try submitSelection(client);
/// ```
pub fn submitSelection(client: *Client) !bool {
    const palette = &client.model.history_palette;
    if (palette.len == 0) {
        return true;
    }

    const prompt = client.model.name_prompt.currentConst() orelse return true;
    const index = @min(prompt.selection, @as(u16, palette.len) - 1);
    _ = try pane_inputs.expressionPaste(client, palette.slice()[index].commandSlice());
    return true;
}
