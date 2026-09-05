//! Adapts the history palette between the name prompt, the runtime
//! connection and the client model: queries go out per keystroke, only the
//! newest reply lands, and Enter pastes the selected command.

const core = @import("telar-core");
const std = @import("std");
const history_palette = @import("../../model/history_palette.zig");
const name_prompts = @import("name_prompts.zig");
const pane_inputs = @import("pane_inputs.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const connection_outbox = @import("../../connection/outbox.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const Client = @import("../../client.zig");
const schema = core.schema;
const history_application = @import("../../application/input/root.zig").history_browser;

fn handler(client: *Client) history_application.Handler {
    return .{ .model = &client.model };
}

/// Opens the palette and requests the unfiltered newest history.
///
/// ```zig
/// _ = try begin(client);
/// ```
pub fn begin(client: *Client) !bool {
    if (!name_prompts.beginHistoryPalette(client)) {
        return false;
    }

    handler(client).begin(.{ .enter_runs = client.history_enter_runs, .match_fuzzy = !client.history_match_fts });
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
    handler(client).restart();
    try sendPage(client, query);
}

fn sendPage(client: *Client, query: []const u8) !void {
    const request_id = try request_lifecycle.nextId(client);

    var owned: connection_outbox.OwnedHistoryQuery = .{
        .request_id = request_id,
        .query_len = @intCast(@min(query.len, connection_outbox.OwnedHistoryQuery.max_query_bytes)),
        .author = if (client.history_show_agent_commands) .all else .human,
        .match = if (client.history_match_fts) .fts else .fuzzy,
        .limit = history_palette.max_entries,
        .offset = client.model.history_palette.pending_offset,
        .snapshot_id = client.model.history_palette.snapshot_id,
    };
    @memcpy(owned.query[0..owned.query_len], query[0..owned.query_len]);
    applyScope(client, &owned);
    if (!handler(client).requestPage(schema.id.raw(request_id), owned.scope)) {
        return;
    }

    runtime_transport.enqueue(client, .{ .query_history = owned }) catch |err| {
        _ = failed(client, .{ .request_id = request_id, .code = .resource_limit, .message = "History request queue is full; retry" });
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
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

    const changed = handler(client).apply(.{
        .request_id = schema.id.raw(view.request_id),
        .entries = storage[0..count],
        .snapshot_id = view.snapshot_id,
        .has_more = view.has_more,
        .now_ms = @intCast(std.Io.Timestamp.now(client.io, .real).toMilliseconds()),
    });
    if (changed) {
        try refreshInspection(client);
    }

    return changed;
}

/// Loads selected detail only on demand and contains expected queue saturation.
/// Example: `try refreshInspection(client);`.
pub fn refreshInspection(client: *Client) !void {
    for (0..2) |_| {
        const read = handler(client).nextRead() orelse return;
        const request_id = try request_lifecycle.nextId(client);
        if (!handler(client).requestRead(schema.id.raw(request_id), read)) {
            return;
        }

        const message: connection_outbox.Message = switch (read.kind) {
            .command => .{ .query_history = .{ .request_id = request_id, .entry_id = read.id, .limit = 1 } },
            .output => .{ .read_history_output = .{ .request_id = request_id, .id = read.id } },
        };
        try enqueue(client, message, request_id);
    }
}

/// Pages in bounded batches while retaining the first query's insertion boundary.
/// Example: `try navigatePage(client);`.
pub fn navigatePage(client: *Client) !void {
    if (handler(client).navigate()) {
        try sendPage(client, client.model.name_prompt.currentConst().?.field.text());
    }
}

/// Delivers output through the history application boundary.
/// Example: `_ = output(client, reply);`.
pub fn output(client: *Client, reply: schema.HistoryOutput) bool {
    return handler(client).output(reply);
}

/// Consumes owned failures, including stale history requests.
/// Example: `if (failed(client, failure)) return;`.
pub fn failed(client: *Client, failure: schema.RequestFailed) bool {
    return handler(client).fail(failure);
}

fn enqueue(client: *Client, message: connection_outbox.Message, request_id: schema.RequestId) !void {
    runtime_transport.enqueue(client, message) catch |err| {
        _ = failed(client, .{ .request_id = request_id, .code = .resource_limit, .message = "History queue is full; change selection or retry" });
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
}

/// Blocks incomplete or oversized pastes while keeping the browser open.
/// Example: `if (!canSubmit(client, selection)) return;`.
pub fn canSubmit(client: *Client, selection: u16) bool {
    const palette = &client.model.history_palette;
    const command = palette.commandAt(selection) orelse {
        handler(client).reject(if (palette.phase == .loading) "Searching..." else "Command unavailable or capture truncated; cannot paste");
        return false;
    };
    const active = client.model.workspace.activeConst() orelse return false;
    const pane = active.model.focusedPaneConst() orelse return false;
    const pane_input = @import("../../application/input/root.zig").pane_input;
    pane_input.validateHistoryText(command, pane.input_modes.bracketed_paste) catch |err| {
        handler(client).reject(if (err == error.UnframedHistoryText) "Multiline/tab paste requires shell bracketed-paste support" else "Command contains terminal controls; cannot paste");
        return false;
    };

    const slots = (command.len + 13 + connection_outbox.max_input_bytes - 1) / connection_outbox.max_input_bytes;
    if (runtime_transport.availableCapacity(client) < slots + 1) {
        handler(client).reject("Input is busy; retry the command");
        return false;
    }

    return true;
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
    const command = palette.commandAt(index) orelse return;
    _ = try pane_inputs.historyPaste(client, .{ .text = command, .run = request.run });
}

pub const PasteRequest = struct {
    selection: u16,
    run: bool,
};

/// Sends one exact-entry deletion for the palette's selected row. The
/// runtime answers with `history_pruned`, which requeries the palette so
/// the row disappears only once it is actually gone.
///
/// ```zig
/// try deleteSelected(client, selection);
/// ```
pub fn deleteSelected(client: *Client, selection: u16) !void {
    const request_id = try request_lifecycle.nextId(client);
    const id = handler(client).requestDelete(schema.id.raw(request_id), selection) orelse return;
    try enqueue(client, .{ .delete_history = .{ .request_id = request_id, .id = id } }, request_id);
}

/// Requeries the palette after the runtime confirmed a deletion.
///
/// ```zig
/// _ = try pruned(client, confirmation);
/// ```
pub fn pruned(client: *Client, confirmation: schema.HistoryPruned) !bool {
    if (!handler(client).pruned(schema.id.raw(confirmation.request_id))) {
        return false;
    }

    try sendQuery(client, client.model.name_prompt.currentConst().?.field.text());
    return true;
}
