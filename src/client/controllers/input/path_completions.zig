//! Owns the working-directory completion of the new-context form: one
//! bounded listing at a time on the observation path, the latest typed
//! query replacing any queued one, stale results discarded by execution
//! identity and the landed list kept in disposable model state.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const path_expansion = @import("../../completion/path_expansion.zig");
const CompletionType = @import("../../completion/PathCompletionCompletion.zig");
const ResultType = @import("../../model/PathCompletionResult.zig");

pub const max_path_bytes = path_expansion.max_path_bytes;

pub const DirectoryStatus = enum { directory, missing, other };

/// Starts the completion list when the form opens.
///
/// ```zig
/// try open(client);
/// ```
pub fn open(client: *Client) !void {
    client.model.path_completion.begin();
    client.path_completions.reset();
    try refresh(client);
}

/// Relists after the directory text changed. The expanded query is compared
/// with the wanted one, so selection moves and name edits start nothing.
///
/// ```zig
/// try refresh(client);
/// ```
pub fn refresh(client: *Client) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    if (prompt.form() == null) {
        return;
    }

    var buffer: [max_path_bytes]u8 = undefined;
    const text = prompt.directory.text();
    const expanded = expandDirectory(client, text, &buffer) catch {
        client.model.path_completion.invalidate();
        client.path_completions.reset();
        return;
    };
    const query = listingQuery(text, expanded, &buffer);
    if (!client.path_completions.want(query)) {
        return;
    }
    if (client.model.path_completion.matches(query)) {
        return;
    }

    try startIfIdle(client);
}

/// Lands one worker result. A result for another execution, or for a query
/// the form already moved past, is released without touching the model.
///
/// ```zig
/// try complete(client, completion);
/// ```
pub fn complete(client: *Client, completion: CompletionType) !void {
    const result = completion.result catch null;
    defer if (result) |owned| client.gpa.destroy(owned);
    if (!client.path_completions.finish(completion.execution_id)) {
        return;
    }
    if (client.path_completions.superseded() or client.model.name_prompt.currentConst() == null) {
        try startIfIdle(client);
        return;
    }
    if (result) |owned| {
        _ = client.model.path_completion.apply(completion.execution_id, .{
            .query = client.path_completions.inflightSlice(),
            .result = owned,
        });
    } else {
        client.model.path_completion.invalidate();
    }
}

/// Replaces the directory text with the selected completion when the list
/// describes the current query; the field keeps its text otherwise.
///
/// ```zig
/// try acceptSelected(client);
/// ```
pub fn acceptSelected(client: *Client) !void {
    const prompt = client.model.name_prompt.currentConst() orelse return;
    const entries = client.model.path_completion.entries();
    if (entries.len == 0 or !client.model.path_completion.matches(client.path_completions.wantedSlice())) {
        return;
    }

    const index = @min(prompt.selection(), entries.len - 1);
    var buffer: [max_path_bytes]u8 = undefined;
    const path = client.model.path_completion.result.join(index, &buffer);
    if (path.len + 1 > max_path_bytes) {
        return;
    }

    buffer[path.len] = '/';
    client.model.name_prompt.replaceDirectory(buffer[0 .. path.len + 1]);
    try refresh(client);
}

/// Forgets the list when the form closes. A running listing completes into
/// nothing.
///
/// ```zig
/// close(client);
/// ```
pub fn close(client: *Client) void {
    client.model.path_completion.begin();
    client.path_completions.reset();
}

/// Expands the typed directory against the focused pane's cwd.
///
/// ```zig
/// const cwd = try expandDirectory(client, submission.directory, &buffer);
/// ```
pub fn expandDirectory(client: *const Client, text: []const u8, buffer: *[max_path_bytes]u8) ![]const u8 {
    return path_expansion.expand(.{
        .text = text,
        .environ = client.options.environ,
        .base = focusedPaneCwd(client),
    }, buffer);
}

/// One `stat` on submit, so a missing directory can ask for confirmation
/// before any request leaves the client.
///
/// ```zig
/// if (directoryStatus(client, cwd) == .missing) prompt.requestDirectoryConfirmation();
/// ```
pub fn directoryStatus(client: *const Client, path: []const u8) DirectoryStatus {
    const stat = std.Io.Dir.cwd().statFile(client.io, path, .{}) catch return .missing;
    return if (stat.kind == .directory) .directory else .other;
}

fn listingQuery(text: []const u8, expanded: []const u8, buffer: *[max_path_bytes]u8) []const u8 {
    const children = text.len == 0 or path_expansion.endsWithSeparator(text);
    if (!children or expanded.len == 0 or expanded[expanded.len - 1] == '/' or expanded.len + 1 > max_path_bytes) {
        return expanded;
    }

    buffer[expanded.len] = '/';
    return buffer[0 .. expanded.len + 1];
}

fn startIfIdle(client: *Client) !void {
    if (client.path_completions.execution != .none or client.path_completions.wanted_len == 0) {
        return;
    }

    const id = client.path_completions.reserve();
    client.model.path_completion.expect(id);
    client.path_completion_runner.start(.init(id, client.path_completions.inflightSlice())) catch |err| {
        client.path_completions.execution = .none;
        return err;
    };
}

fn focusedPaneCwd(client: *const Client) []const u8 {
    const active = client.model.workspace.activeConst() orelse return "";
    const pane = active.model.focusedPaneConst() orelse return "";
    return pane.cwdSlice();
}

comptime {
    _ = ResultType;
}
