//! History palette: queries, pages, pastes and deletes command history rows.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const history_browser = @import("history_browser.zig");
const encoding_support = @import("encoding_support.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const name_prompt = @import("name_prompt.zig");
const pane_input = @import("../panes/pane_input.zig");
const Client = @import("../AttachedClient.zig");

/// Blocks incomplete or oversized pastes while keeping the browser open.
/// Example: `_ = history_palette.canSubmitHistory(client, selection);`
pub fn canSubmitHistory(client: *Client, selection: u16) bool {
    const palette = &client.model.history_palette;
    const command = palette.commandAt(selection) orelse {
        client.model.history_palette.setError(if (palette.phase == .loading) "Searching..." else "Command unavailable or capture truncated; cannot paste");
        return false;
    };

    const active = client.model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(&client.model, active) orelse return false;
    pane_input.validateHistoryText(command, pane.input_modes.bracketed_paste) catch |err| {
        client.model.history_palette.setError(if (err == error.UnframedHistoryText) "Multiline/tab paste requires shell bracketed-paste support" else "Command contains terminal controls; cannot paste");
        return false;
    };

    const slots = (command.len + 13 + data.input_limits.max_encoded_bytes - 1) / data.input_limits.max_encoded_bytes;
    if (client.model.to_runtime.availableCapacity() < slots + 1) {
        client.model.history_palette.setError("Input is busy; retry the command");
        return false;
    }

    return true;
}

/// Selects a command from a delivered history page without pasting or running
/// it. Example: `try selectHistoryRow(client, index, page_revision);`.
/// Example: `try history_palette.selectHistoryRow(app, index, revision);`
pub fn selectHistoryRow(client: *Client, index: u16, revision: u64) !void {
    if (!history_browser.select(
        &client.model,
        index,
        revision,
    )) {
        return;
    }

    try refreshHistoryInspection(client);
}

/// Scrolls output by logical lines and reapplies the adapter's exact bound.
/// Example: `try scrollHistoryInspection(client, 1);`.
/// Example: `try history_palette.scrollHistoryInspection(app, lines);`
pub fn scrollHistoryInspection(client: *Client, lines: i16) !void {
    history_browser.scrollInspection(&client.model, lines);
    try refreshHistoryInspection(client);
}

/// Sends one bounded history query in the palette's current scope and
/// awaits only its reply. A scope whose value cannot be resolved from the
/// committed model falls back to global.
/// Example: `try history_palette.queryHistory(client, query);`
pub fn queryHistory(client: *Client, query: []const u8) !void {
    history_browser.restart(&client.model);
    try requestHistoryPage(client, query);
}

/// Loads selected detail only on demand and contains expected queue saturation.
/// Example: `try history_palette.refreshHistoryInspection(client);`
pub fn refreshHistoryInspection(client: *Client) !void {
    for (0..2) |_| {
        const next = history_browser.nextRead(&client.model);
        if (client.chrome.inspectionScrollLimit()) |limit| {
            history_browser.constrainInspection(&client.model, limit);
        }

        const read = next orelse return;
        const request_id = try client.model.request_lifecycle.nextId();
        if (!history_browser.requestRead(
            &client.model,
            core.raw(request_id),
            read,
        )) {
            return;
        }

        const message: data.outbox_support.Message = switch (read.kind) {
            .command => .{
                .query_history = .{
                    .request_id = request_id,
                    .entry_id = read.id,
                    .limit = 1,
                },
            },
            .output => .{
                .read_history_output = .{
                    .request_id = request_id,
                    .id = read.id,
                },
            },
        };

        try enqueueHistoryRequest(client, message, request_id);
    }
}

/// Pages in bounded batches while retaining the first query's insertion boundary.
/// Example: `try history_palette.navigateHistoryPage(client);`
pub fn navigateHistoryPage(client: *Client) !void {
    if (history_browser.navigate(&client.model)) {
        try requestHistoryPage(client, client.model.name_prompt.currentConst().?.field.text());
    }
}

/// Pastes the selected command into the focused pane, optionally running it
/// by appending Enter. Runs after the prompt closed, because
/// `planPaneInput(.focused)` refuses input while a prompt is active; an
/// empty result list means there is nothing to paste.
/// Example: `try history_palette.pasteHistorySelection(client, request);`
pub fn pasteHistorySelection(client: *Client, request: data.HistoryPasteRequest) !void {
    const palette = &client.model.history_palette;
    if (palette.len == 0) {
        return;
    }

    const index = @min(request.selection, @as(u16, palette.len) - 1);
    const command = palette.commandAt(index) orelse return;
    _ = try pasteHistoryCommand(client, command, request.run);
}

/// Sends one exact-entry deletion for the palette's selected row. The
/// runtime answers with `history_pruned`, which requeries the palette so
/// the row disappears only once it is actually gone.
/// Example: `try history_palette.deleteHistorySelection(client, selection);`
pub fn deleteHistorySelection(client: *Client, selection: u16) !void {
    const request_id = try client.model.request_lifecycle.nextId();
    const id = history_browser.requestDelete(
        &client.model,
        core.raw(request_id),
        selection,
    ) orelse return;
    try enqueueHistoryRequest(
        client,
        .{
            .delete_history = .{
                .request_id = request_id,
                .id = id,
            },
        },
        request_id,
    );
}

/// Opens the palette and requests the unfiltered newest history.
pub fn beginHistoryPalette(client: *Client) !bool {
    if (!name_prompt.openNamePrompt(client, .history_palette)) {
        return false;
    }

    history_browser.begin(
        &client.model,
        .{
            .enter_runs = client.model.config.history_enter_runs,
            .match_fuzzy = !client.model.config.history_match_fts,
        },
    );
    try queryHistory(client, "");
    return true;
}

fn requestHistoryPage(client: *Client, query: []const u8) !void {
    const request_id = try client.model.request_lifecycle.nextId();

    var owned: data.OwnedHistoryQuery = .{
        .request_id = request_id,
        .query_len = @intCast(@min(query.len, data.OwnedHistoryQuery.max_query_bytes)),
        .author = if (client.model.config.history_show_agent_commands) .all else .human,
        .match = if (client.model.config.history_match_fts) .fts else .fuzzy,
        .limit = core.max_history_results,
        .offset = client.model.history_palette.pending_offset,
        .snapshot_id = client.model.history_palette.snapshot_id,
    };
    @memcpy(owned.query[0..owned.query_len], query[0..owned.query_len]);
    resolveHistoryScope(&client.model, &owned);
    if (!client.model.history_palette.beginPageRequest(core.raw(request_id), owned.scope)) {
        return;
    }

    runtime_io.sendRuntime(
        client,
        .{
            .query_history = owned,
        },
    ) catch |err| {
        _ = client.model.history_palette.fail(
            .{
                .request_id = request_id,
                .code = .resource_limit,
                .message = "History request queue is full; retry",
            },
        );
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
}

fn resolveHistoryScope(model: *const data.ClientModel, owned: *data.OwnedHistoryQuery) void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (prompt.target() != .history) {
        return;
    }

    switch (prompt.scope()) {
        .global => {},
        .workspace => {
            const location = model.workspace orelse return;
            const workspace = switch (location) {
                .workspace => |workspace| workspace,
                .worktree => return,
            };

            const list = &model.workspace_list_snapshot;
            const index = list.indexOf(workspace) orelse return;
            const path = list.pathAt(index);
            if (path.len == 0 or path.len > data.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .workspace;
            @memcpy(owned.scope_value[0..path.len], path);
            owned.scope_value_len = @intCast(path.len);
        },
        .cwd => {
            const active = model.tabs.activeSlot() orelse return;
            const pane = data.tab_layout.focusedPaneConst(model, active) orelse return;
            const cwd = pane.cwdSlice();
            if (cwd.len == 0 or cwd.len > data.OwnedHistoryQuery.max_scope_bytes) {
                return;
            }

            owned.scope = .cwd;
            @memcpy(owned.scope_value[0..cwd.len], cwd);
            owned.scope_value_len = @intCast(cwd.len);
        },
        .pane => {
            const active = model.tabs.activeSlot() orelse return;
            const pane = data.tab_layout.focusedPaneConst(model, active) orelse return;
            owned.scope = .pane;
            owned.pane_id = pane.id;
        },
    }
}

/// Applies one runtime reply to the palette model. Stale replies and replies
/// arriving after the palette closed change nothing visible.
pub fn applyHistoryResults(client: *Client, view: core.HistoryResultsView) !bool {
    var storage: [core.max_history_results]core.HistoryEntry = undefined;
    var count: usize = 0;
    var iterator = view.entries();
    while (try iterator.next()) |entry| {
        if (count == storage.len) {
            break;
        }

        storage[count] = entry;
        count += 1;
    }

    const changed = history_browser.apply(
        &client.model,
        .{
            .request_id = core.raw(view.request_id),
            .entries = storage[0..count],
            .snapshot_id = view.snapshot_id,
            .has_more = view.has_more,
            .now_ms = @intCast(std.Io.Timestamp.now(client.io, .real).toMilliseconds()),
        },
    );
    if (changed) {
        try refreshHistoryInspection(client);
    }

    return changed;
}

fn enqueueHistoryRequest(client: *Client, message: data.outbox_support.Message, request_id: core.RequestId) !void {
    runtime_io.sendRuntime(client, message) catch |err| {
        _ = client.model.history_palette.fail(
            .{
                .request_id = request_id,
                .code = .resource_limit,
                .message = "History queue is full; change selection or retry",
            },
        );
        if (err != error.ClientOutboxFull) {
            return err;
        }
    };
}

/// Requeries the palette after the runtime confirmed a deletion.
pub fn completeHistoryPrune(client: *Client, confirmation: core.HistoryPruned) !bool {
    if (!history_browser.pruned(&client.model, core.raw(confirmation.request_id))) {
        return false;
    }

    try queryHistory(client, client.model.name_prompt.currentConst().?.field.text());
    return true;
}

/// Delivers one history command, with execution outside bracketed paste framing.
/// Example: `_ = try historyPaste(client, .{ .text = command, .run = false });`.
fn pasteHistoryCommand(client: *Client, text: []const u8, run: bool) !?data.PaneInputDelivery {
    const started = core.now(client.io);

    const plan = client.model.planPaneInput(.focused) orelse return null;
    try pane_input.validateHistoryText(text, plan.input_modes.bracketed_paste);
    var encoded: [core.max_history_command_bytes + 13]u8 = undefined;
    const paste = try encoding_support.encodePaste(
        &encoded,
        text,
        plan.input_modes,
    );
    var len = paste.len;
    if (run) {
        encoded[len] = '\r';
        len += 1;
    }

    return pane_input.recordPaneInput(client, started, try pane_input.deliverPaneInput(
        client,
        plan,
        .{
            .source = .paste,
            .bytes = encoded[0..len],
            .limit = encoded.len,
        },
    ));
}
