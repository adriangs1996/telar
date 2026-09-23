//! Prompt path completion: completes directory paths typed in the name prompt
//! on a worker.
const data = @import("model");
const std = @import("std");
const path_queries = @import("../input/path_completions.zig");
const path_expansion = @import("path_expansion.zig");
const Client = @import("../AttachedClient.zig");

/// Lands one worker result. A result for another execution, or for a query
/// the form already moved past, is released without touching the model.
/// Example: `try prompt_paths.completePathCompletion(app, completion);`
pub fn completePathCompletion(client: *Client, completion: data.PathCompletionCompletion) !void {
    const result = completion.result catch null;
    defer if (result) |owned| client.gpa.destroy(owned);
    const completion_state = &client.model.path_completion;
    if (!completion_state.retire(completion.execution_id)) {
        return;
    }
    if (completion_state.superseded() or client.model.name_prompt.currentConst() == null) {
        try startPathCompletion(client);
        return;
    }
    if (result) |owned| {
        completion_state.land(.{
            .query = completion_state.inflightSlice(),
            .result = owned,
        });
    } else {
        client.model.path_completion.invalidate();
    }
}

/// Starts the completion list when the form opens.
pub fn openPathCompletion(client: *Client) !void {
    client.model.path_completion.begin();
    try refreshPathCompletion(client);
}

/// Relists after the directory text changed. The expanded query is compared
/// with the wanted one, so selection moves and name edits start nothing.
pub fn refreshPathCompletion(client: *Client) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.form() == null) {
        return;
    }

    var buffer: [path_expansion.max_path_bytes]u8 = undefined;
    const text = prompt.directory.text();
    const expanded = expandPromptDirectory(client, text, &buffer) catch {
        client.model.path_completion.invalidate();
        client.model.path_completion.forgetQuery();
        return;
    };
    const query = path_queries.listingQuery(
        text,
        expanded,
        &buffer,
    );
    if (!client.model.path_completion.want(query)) {
        return;
    }
    if (client.model.path_completion.matches(query)) {
        return;
    }

    try startPathCompletion(client);
}

/// Replaces the directory text with the selected completion when the list
/// describes the current query; the field keeps its text otherwise.
pub fn acceptPathCompletion(client: *Client) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    const entries = client.model.path_completion.entries();
    if (entries.len == 0 or !client.model.path_completion.matches(client.model.path_completion.wantedSlice())) {
        return;
    }

    const index = @min(prompt.selection(), entries.len - 1);
    var buffer: [path_expansion.max_path_bytes]u8 = undefined;
    const path = client.model.path_completion.result.join(index, &buffer);
    if (path.len + 1 > path_expansion.max_path_bytes) {
        return;
    }

    buffer[path.len] = '/';
    client.model.name_prompt.replaceDirectory(buffer[0 .. path.len + 1]);
    try refreshPathCompletion(client);
}

/// Forgets the list when the form closes. A running listing completes into
/// nothing.
pub fn closePathCompletion(client: *Client) void {
    client.model.path_completion.begin();
}

/// Expands the typed directory against the focused pane's cwd.
pub fn expandPromptDirectory(client: *const Client, text: []const u8, buffer: *[path_expansion.max_path_bytes]u8) ![]const u8 {
    return path_expansion.expand(
        .{
            .text = text,
            .environ = client.options.environ,
            .base = focusedPaneCwd(&client.model),
        },
        buffer,
    );
}

/// One `stat` on submit, so a missing directory can ask for confirmation
/// before any request leaves the client.
pub fn promptDirectoryStatus(client: *const Client, path: []const u8) path_queries.DirectoryStatus {
    const stat = std.Io.Dir.cwd().statFile(
        client.io,
        path,
        .{},
    ) catch return .missing;
    return if (stat.kind == .directory) .directory else .other;
}

fn startPathCompletion(client: *Client) !void {
    const completion_state = &client.model.path_completion;
    if (completion_state.pending != .none or completion_state.wanted_len == 0) {
        return;
    }

    const id = completion_state.reserve();
    client.to_workers.push(.{ .path_completion = .init(id, completion_state.inflightSlice()) }) catch |err| {
        completion_state.pending = .none;
        return err;
    };
}

fn focusedPaneCwd(model: *const data.ClientModel) []const u8 {
    const active = model.tabs.activeSlot() orelse return "";
    const pane = data.tab_layout.focusedPaneConst(model, active) orelse return "";
    return pane.cwdSlice();
}
