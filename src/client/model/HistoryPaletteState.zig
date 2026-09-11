const State = @This();
const source_namespace = @import("history_palette.zig");
const Entry = @import("Entry.zig");
const std = @import("std");
const Storage = struct {
    commands: [source_namespace.max_command_storage]u8 = undefined,
    output: [source_namespace.schema.max_history_output_bytes]u8 = undefined,
    selected_command: [source_namespace.schema.max_history_command_bytes]u8 = undefined,
};

revision: u64 = 0,
pending_request: u64 = 0,
entries: [source_namespace.max_entries]Entry = undefined,
len: u8 = 0,
phase: enum { idle, loading, ready, failed } = .idle,
now_ms: i64 = 0,
enter_runs: bool = false,
match_fuzzy: bool = true,
effective_scope: source_namespace.schema.HistoryScope = .global,
storage: ?*Storage = null,
allocator: ?std.mem.Allocator = null,
commands_len: u32 = 0,
output_len: u32 = 0,
output_request: u64 = 0,
output_id: u64 = 0,
output_phase: enum { idle, loading, ready, failed } = .idle,
output_truncated: bool = false,
error_text: [128]u8 = undefined,
error_len: u8 = 0,
requests: [128]u64 = @splat(0),
delete_request: u64 = 0,
page_offset: u32 = 0,
pending_offset: u32 = 0,
snapshot_id: u64 = 0,
has_more: bool = false,
full_request: u64 = 0,
full_id: u64 = 0,
full_len: u32 = 0,

/// Allocates bounded history storage once before the client input loop starts.
/// Example: `try state.prepare(gpa);`.
pub fn prepare(state: *State, gpa: std.mem.Allocator) !void {
    if (state.storage != null) {
        return;
    }

    state.storage = try gpa.create(Storage);
    state.allocator = gpa;
}

/// Releases storage after all client callbacks have stopped.
/// Example: `defer state.deinit();`.
pub fn deinit(state: *State) void {
    if (state.storage) |storage| {
        state.allocator.?.destroy(storage);
        state.storage = null;
    }
}

/// Clears previous results when the palette opens.
///
/// ```zig
/// model.history_palette.begin();
/// ```
pub fn begin(state: *State) void {
    state.len = 0;
    state.pending_request = 0;
    state.phase = .idle;
    state.commands_len = 0;
    state.clearOutput();
    state.error_len = 0;
    state.page_offset = 0;
    state.pending_offset = 0;
    state.snapshot_id = 0;
    state.has_more = false;
    state.full_id = 0;
    state.full_request = 0;
    state.full_len = 0;
    state.revision +%= 1;
}

/// Starts a search generation without reusing the previous insertion boundary.
/// Example: `state.restartQuery();`.
pub fn restartQuery(state: *State) void {
    state.snapshot_id = 0;
    state.pending_offset = 0;
}

pub fn configure(state: *State, options: struct { enter_runs: bool, match_fuzzy: bool }) void {
    state.enter_runs = options.enter_runs;
    state.match_fuzzy = options.match_fuzzy;
}

pub const PageResult = struct {
    request_id: u64,
    entries: []const source_namespace.schema.HistoryEntry,
    snapshot_id: u64,
    has_more: bool,
    now_ms: i64,
};

/// Reserves correlation and replaces actionable rows in one transition.
/// Example: `if (!state.beginPageRequest(id, .global)) return;`.
pub fn beginPageRequest(state: *State, id: u64, scope: source_namespace.schema.HistoryScope) bool {
    if (id == 0 or !state.track(id)) {
        state.rejectQuery();
        return false;
    }

    state.effective_scope = scope;
    state.expect(id);
    return true;
}

/// Commits entries, pagination and display time under a single revision.
/// Example: `_ = state.acceptPageResult(page);`.
pub fn acceptPageResult(state: *State, result: PageResult) bool {
    if (!state.applyEntries(result.request_id, result.entries)) {
        return false;
    }

    state.snapshot_id = result.snapshot_id;
    state.has_more = result.has_more;
    state.now_ms = result.now_ms;
    state.pending_request = 0;
    state.revision +%= 1;
    return true;
}

/// Plans an adjacent bounded page; the visible page remains until its reply lands.
/// Example: `if (state.page(.older)) requestPage();`.
pub fn page(state: *State, direction: enum { older, newer }) bool {
    if (state.phase != .ready or state.len == 0) {
        return false;
    }

    switch (direction) {
        .older => {
            if (!state.has_more) {
                return false;
            }

            state.pending_offset = state.page_offset +| state.len;
        },
        .newer => {
            if (state.page_offset == 0) {
                return false;
            }

            state.pending_offset = state.page_offset -| source_namespace.max_entries;
        },
    }

    return true;
}

/// Prevents submitting previous results when no new request can be admitted.
/// Example: `state.rejectQuery();`.
fn rejectQuery(state: *State) void {
    state.phase = .failed;
    state.pending_request = 0;
}

pub fn expectFull(state: *State, request: struct { request_id: u64, id: u64 }) void {
    state.full_request = request.request_id;
    state.full_id = request.id;
    state.full_len = 0;
}

pub fn expectDelete(state: *State, request_id: u64) void {
    state.delete_request = request_id;
}

/// Retires deletion acknowledgements without letting an old one refresh a new search.
/// Example: `if (state.pruned(request_id)) refresh();`.
pub fn pruned(state: *State, request_id: u64) bool {
    _ = state.retire(request_id);
    if (request_id == 0 or request_id != state.delete_request) {
        return false;
    }

    state.delete_request = 0;
    return true;
}

/// Records the request whose reply the palette is waiting for. Older
/// in-flight replies become stale immediately.
///
/// ```zig
/// Internal half of beginPageRequest; never exposed independently.
/// ```
fn expect(state: *State, request_id: u64) void {
    state.pending_request = request_id;
    state.phase = .loading;
    state.full_id = 0;
    state.full_request = 0;
    state.full_len = 0;
    state.error_len = 0;
    state.clearOutput();
    state.revision +%= 1;
}

/// Copies one reply's entries into bounded storage. Replies for any other
/// request than the awaited one are ignored.
///
/// ```zig
/// Internal half of acceptPageResult; metadata commits before publication.
/// ```
fn applyEntries(state: *State, request_id: u64, entries: []const source_namespace.schema.HistoryEntry) bool {
    _ = state.retire(request_id);
    if (request_id == 0 or request_id != state.pending_request or state.phase != .loading) {
        return false;
    }

    state.len = 0;
    state.commands_len = 0;
    for (entries) |*entry| {
        if (state.len == source_namespace.max_entries) {
            break;
        }

        var stored: Entry = .{
            .id = entry.id,
            .status = entry.status,
            .author = entry.author,
            .exit_code = entry.exit_code,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .captured_truncated = entry.command_truncated,
        };
        if (entry.command.len <= source_namespace.max_command_bytes) {
            stored.command_complete = true;
        } else if (state.storage) |storage| {
            if (entry.command.len <= storage.commands.len - state.commands_len) {
                stored.full_offset = state.commands_len;
                stored.full_len = @intCast(entry.command.len);
                @memcpy(storage.commands[state.commands_len..][0..entry.command.len], entry.command);
                state.commands_len += stored.full_len;
                stored.command_complete = true;
            }
        }

        stored.command_len = source_namespace.copyBounded(&stored.command, entry.command);
        stored.cwd_len = @intCast(source_namespace.copyBounded(&stored.cwd, entry.cwd));
        state.entries[state.len] = stored;
        state.len += 1;
    }

    state.phase = .ready;
    state.page_offset = state.pending_offset;
    return true;
}

/// Returns the full command only when the current reply owns every byte.
/// Example: `const command = state.commandAt(selection) orelse return;`.
pub fn commandAt(state: *const State, index: u16) ?[]const u8 {
    if (state.phase != .ready or index >= state.len) {
        return null;
    }

    const entry = &state.entries[index];
    if (entry.captured_truncated) {
        return null;
    }

    if (state.full_id == entry.id and state.full_len != 0) {
        return state.storage.?.selected_command[0..state.full_len];
    }

    if (!entry.command_complete) {
        return null;
    }

    if (entry.full_len == 0) {
        return entry.commandSlice();
    }

    return state.storage.?.commands[entry.full_offset..][0..entry.full_len];
}

/// Invalidates a closed inspector without accepting late output.
/// Example: `state.clearOutput();`.
pub fn clearOutput(state: *State) void {
    state.output_request = 0;
    state.output_id = 0;
    state.output_len = 0;
    state.output_phase = .idle;
    state.output_truncated = false;
}

/// Associates one bounded output read with its exact entry.
/// Example: `state.expectOutput(.{ .request_id = 7, .id = 3 });`.
pub fn expectOutput(state: *State, request: struct { request_id: u64, id: u64 }) void {
    state.clearOutput();
    state.output_request = request.request_id;
    state.output_id = request.id;
    state.output_phase = .loading;
    state.revision +%= 1;
}

/// Owns output before the receive buffer is reused; stale selections are ignored.
/// Example: `_ = state.applyOutput(reply);`.
pub fn applyOutput(state: *State, reply: source_namespace.schema.HistoryOutput) bool {
    _ = state.retire(source_namespace.schema.id.raw(reply.request_id));
    if (state.output_request == 0 or source_namespace.schema.id.raw(reply.request_id) != state.output_request or reply.id != state.output_id) {
        return false;
    }

    const storage = state.storage orelse return false;
    const len = @min(reply.content.len, storage.output.len);
    @memcpy(storage.output[0..len], reply.content[0..len]);
    state.output_len = @intCast(len);
    state.output_truncated = reply.truncated or len != reply.content.len;
    state.output_phase = .ready;
    state.revision +%= 1;
    return true;
}

/// Keeps observation failures local to their query or inspector.
/// Example: `_ = state.fail(reply);`.
pub fn fail(state: *State, failure: source_namespace.schema.RequestFailed) bool {
    const request = source_namespace.schema.id.raw(failure.request_id);
    const owned = state.retire(request);
    if (request == state.pending_request and request != 0) {
        state.phase = .failed;
    } else if (request == state.output_request and request != 0) {
        state.output_phase = .failed;
    } else if (request == state.delete_request and request != 0) {
        state.delete_request = 0;
    } else if (request == state.full_request and request != 0) {
        state.full_request = 0;
    } else {
        return owned;
    }

    state.setError(failure.message);
    return true;
}

/// Records a local actionable error without closing the history browser.
/// Example: `state.setError("Command unavailable");`.
pub fn setError(state: *State, message: []const u8) void {
    state.error_len = @intCast(source_namespace.copyBounded(&state.error_text, message));
    state.revision +%= 1;
}

pub fn errorSlice(state: *const State) []const u8 {
    return state.error_text[0..state.error_len];
}

pub fn outputSlice(state: *const State) []const u8 {
    const storage = state.storage orelse return "";
    return storage.output[0..state.output_len];
}

pub fn outputHint(state: *const State) []const u8 {
    return switch (state.output_phase) {
        .idle => "No captured output",
        .loading => "Loading captured output...",
        .failed => "Could not read captured output",
        .ready => if (state.output_len == 0) "No captured output" else if (state.output_truncated) "Captured output (truncated)" else "Captured output",
    };
}

/// Loads one complete command when the page's shared storage quota was exhausted.
/// Example: `_ = state.applyFull(reply_id, entries);`.
pub fn applyFull(state: *State, request_id: u64, entries: []const source_namespace.schema.HistoryEntry) bool {
    if (request_id == 0 or request_id != state.full_request) {
        return false;
    }

    _ = state.retire(request_id);
    const storage = state.storage orelse return false;
    if (entries.len != 1 or entries[0].id != state.full_id or entries[0].command_truncated or entries[0].command.len > storage.selected_command.len) {
        state.setError("The selected command is no longer available");
        state.full_request = 0;
        return true;
    }

    const command = entries[0].command;
    @memcpy(storage.selected_command[0..command.len], command);
    state.full_len = @intCast(command.len);
    state.full_request = 0;
    state.error_len = 0;
    state.revision +%= 1;
    return true;
}

/// Reserves correlation before a request enters the asynchronous outbox.
/// Example: `if (!state.track(request_id)) return;`.
pub fn track(state: *State, request_id: u64) bool {
    for (&state.requests) |*pending| {
        if (pending.* == 0) {
            pending.* = request_id;
            return true;
        }
    }

    state.setError("History is busy; retry the search");
    return false;
}

/// Releases a completed request even when its visible state was replaced.
/// Example: `_ = state.retire(request_id);`.
pub fn retire(state: *State, request_id: u64) bool {
    if (request_id == 0) {
        return false;
    }

    for (&state.requests) |*pending| {
        if (pending.* == request_id) {
            pending.* = 0;
            return true;
        }
    }

    return false;
}

pub fn slice(state: *const State) []const Entry {
    return state.entries[0..state.len];
}

pub fn version(state: *const State) u64 {
    return state.revision;
}
