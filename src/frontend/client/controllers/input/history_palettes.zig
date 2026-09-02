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

/// Sends one bounded history query in the palette's current scope and
/// awaits only its reply. A scope whose value cannot be resolved from the
/// committed model falls back to global.
///
/// ```zig
/// try sendQuery(client, prompt.field.text());
/// ```
pub fn sendQuery(client: *Client, query: []const u8) !void {
    const request_id = try request_lifecycle.nextId(client);
    var owned: connection_outbox.OwnedHistoryQuery = .{
        .request_id = request_id,
        .query_len = @intCast(@min(query.len, connection_outbox.OwnedHistoryQuery.max_query_bytes)),
        .author = if (client.history_show_agent_commands) .all else .human,
        .limit = history_palette.max_entries,
    };
    @memcpy(owned.query[0..owned.query_len], query[0..owned.query_len]);
    applyScope(client, &owned);

    client.model.history_palette.expect(schema.id.raw(request_id));
    try runtime_transport.enqueue(client, .{ .query_history = owned });
}

fn applyScope(client: *Client, owned: *connection_outbox.OwnedHistoryQuery) void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.target != .history) {
        return;
    }

    switch (prompt.scope) {
        .global => {},
        .workspace => {
            const location = client.model.workspaceLocation() orelse return;
            const workspace = switch (location) {
                .workspace => |workspace| workspace,
                .worktree => return,
            };
            const list = client.model.workspaceListSnapshot();
            const index = list.indexOf(workspace) orelse return;
            const path = list.pathAt(index);
            if (path.len == 0 or path.len > connection_outbox.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .workspace;
            @memcpy(owned.scope_value[0..path.len], path);
            owned.scope_value_len = @intCast(path.len);
        },
        .cwd => {
            const active = client.model.workspace.activeConst() orelse return;
            const pane = active.model.focusedPaneConst() orelse return;
            const cwd = pane.cwdSlice();
            if (cwd.len == 0 or cwd.len > connection_outbox.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .cwd;
            @memcpy(owned.scope_value[0..cwd.len], cwd);
            owned.scope_value_len = @intCast(cwd.len);
        },
        .pane => {
            const active = client.model.workspace.activeConst() orelse return;
            const pane = active.model.focusedPaneConst() orelse return;
            owned.scope = .pane;
            owned.pane_id = pane.id;
        },
    }
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

/// Pastes the selected command into the focused pane, optionally running it
/// by appending Enter. Runs after the prompt closed, because
/// `planPaneInput(.focused)` refuses input while a prompt is active; an
/// empty result list means there is nothing to paste.
///
/// ```zig
/// try pasteSelection(client, .{ .selection = 0, .run = false });
/// ```
pub fn pasteSelection(client: *Client, request: PasteRequest) !void {
    const palette = &client.model.history_palette;
    if (palette.len == 0) {
        return;
    }

    const index = @min(request.selection, @as(u16, palette.len) - 1);
    const command = palette.slice()[index].commandSlice();
    if (!request.run) {
        _ = try pane_inputs.expressionPaste(client, command);
        return;
    }

    var storage: [history_palette.max_command_bytes + 1]u8 = undefined;
    @memcpy(storage[0..command.len], command);
    storage[command.len] = '\r';
    _ = try pane_inputs.expressionPaste(client, storage[0 .. command.len + 1]);
}

pub const PasteRequest = struct {
    selection: u16,
    run: bool,
};
