//! Bounded storage for the latest history-palette results. The palette only
//! shows the newest reply for the newest query, so stale replies are ignored
//! by request id instead of queued.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_entries = schema.max_history_results;
pub const max_command_bytes = 512;
pub const max_entry_cwd_bytes = 256;
pub const max_command_storage = 768 * 1024;

pub const Entry = struct {
    id: u64 = 0,
    status: schema.HistoryStatus = .completed,
    author: schema.HistoryAuthor = .human,
    exit_code: ?i32 = null,
    pane_id: schema.PaneId = .invalid,
    started_at_ms: i64 = 0,
    duration_ns: i64 = 0,
    full_offset: u32 = 0,
    full_len: u32 = 0,
    command_complete: bool = false,
    captured_truncated: bool = false,
    command: [max_command_bytes]u8 = undefined,
    command_len: u16 = 0,
    cwd: [max_entry_cwd_bytes]u8 = undefined,
    cwd_len: u16 = 0,

    pub fn commandSlice(entry: *const Entry) []const u8 {
        return entry.command[0..entry.command_len];
    }

    pub fn cwdSlice(entry: *const Entry) []const u8 {
        return entry.cwd[0..entry.cwd_len];
    }
};

pub const State = struct {
    const Storage = struct {
        commands: [max_command_storage]u8 = undefined,
        output: [schema.max_history_output_bytes]u8 = undefined,
        selected_command: [schema.max_history_command_bytes]u8 = undefined,
    };

    revision: u64 = 0,
    pending_request: u64 = 0,
    entries: [max_entries]Entry = undefined,
    len: u8 = 0,
    phase: enum { idle, loading, ready, failed } = .idle,
    now_ms: i64 = 0,
    enter_runs: bool = false,
    match_fuzzy: bool = true,
    effective_scope: schema.HistoryScope = .global,
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

    pub fn setScope(state: *State, scope: schema.HistoryScope) void {
        state.effective_scope = scope;
    }

    /// Commits pagination metadata together with the accepted results.
    /// Example: `state.acceptPage(.{ .snapshot_id = 8, .has_more = false, .now_ms = 100 });`.
    pub fn acceptPage(state: *State, result: struct { snapshot_id: u64, has_more: bool, now_ms: i64 }) void {
        state.snapshot_id = result.snapshot_id;
        state.has_more = result.has_more;
        state.now_ms = result.now_ms;
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

                state.pending_offset = state.page_offset -| max_entries;
            },
        }

        return true;
    }

    /// Prevents submitting previous results when no new request can be admitted.
    /// Example: `state.rejectQuery();`.
    pub fn rejectQuery(state: *State) void {
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
    /// model.history_palette.expect(schema.id.raw(request_id));
    /// ```
    pub fn expect(state: *State, request_id: u64) void {
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
    /// _ = model.history_palette.apply(request_id, decoded_entries);
    /// ```
    pub fn apply(state: *State, request_id: u64, entries: []const schema.HistoryEntry) bool {
        _ = state.retire(request_id);
        if (request_id == 0 or request_id != state.pending_request) {
            return false;
        }

        state.len = 0;
        state.commands_len = 0;
        for (entries) |*entry| {
            if (state.len == max_entries) {
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
            if (entry.command.len <= max_command_bytes) {
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

            stored.command_len = copyBounded(&stored.command, entry.command);
            stored.cwd_len = @intCast(copyBounded(&stored.cwd, entry.cwd));
            state.entries[state.len] = stored;
            state.len += 1;
        }

        state.phase = .ready;
        state.page_offset = state.pending_offset;
        state.revision +%= 1;
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
    pub fn applyOutput(state: *State, reply: schema.HistoryOutput) bool {
        _ = state.retire(schema.id.raw(reply.request_id));
        if (state.output_request == 0 or schema.id.raw(reply.request_id) != state.output_request or reply.id != state.output_id) {
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
    pub fn fail(state: *State, failure: schema.RequestFailed) bool {
        const request = schema.id.raw(failure.request_id);
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
        state.error_len = @intCast(copyBounded(&state.error_text, message));
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
    pub fn applyFull(state: *State, request_id: u64, entries: []const schema.HistoryEntry) bool {
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
};

fn copyBounded(buffer: []u8, source: []const u8) u16 {
    var len = @min(buffer.len, source.len);
    while (len < source.len and len > 0 and source[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    @memcpy(buffer[0..len], source[0..len]);
    return @intCast(len);
}

test "only the awaited reply lands and commands stay bounded" {
    var state: State = .{};
    state.begin();
    state.expect(7);

    const long = "x" ** (max_command_bytes + 32);
    const entries = [_]schema.HistoryEntry{
        .{
            .id = 1,
            .pane_id = @enumFromInt(1),
            .started_at_ms = 0,
            .duration_ns = 0,
            .exit_code = 0,
            .status = .completed,
            .command = "git status",
            .cwd = "/work",
            .workspace_path = "/work",
        },
        .{
            .id = 2,
            .pane_id = @enumFromInt(1),
            .started_at_ms = 0,
            .duration_ns = 0,
            .exit_code = null,
            .status = .interrupted,
            .command = long,
            .cwd = "/work",
            .workspace_path = "/work",
        },
    };

    try std.testing.expect(!state.apply(6, &entries));
    try std.testing.expectEqual(@as(u8, 0), state.len);

    try std.testing.expect(state.apply(7, &entries));
    try std.testing.expectEqual(@as(u8, 2), state.len);
    try std.testing.expectEqualStrings("git status", state.slice()[0].commandSlice());
    try std.testing.expectEqual(@as(u16, max_command_bytes), state.slice()[1].command_len);
}

test "history retains full command bytes and rejects actions on stale results" {
    var state: State = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    var command = [_]u8{'x'} ** (max_command_bytes + 100);
    const entry: schema.HistoryEntry = .{ .id = 7, .pane_id = @enumFromInt(1), .started_at_ms = 123, .duration_ns = 9000, .exit_code = 1, .status = .completed, .command = &command, .cwd = "/work", .workspace_path = "/work" };
    state.expect(1);
    try std.testing.expect(state.apply(1, &.{entry}));
    command[0] = 'z';

    const full = state.commandAt(0).?;
    try std.testing.expectEqual(@as(usize, max_command_bytes + 100), full.len);
    try std.testing.expectEqual(@as(u8, 'x'), full[0]);
    try std.testing.expectEqual(@as(i64, 123), state.slice()[0].started_at_ms);
    state.expect(2);
    try std.testing.expect(state.commandAt(0) == null);
}

test "inspector owns output and ignores replies and failures from replaced selections" {
    var state: State = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(state.track(5));
    state.expectOutput(.{ .request_id = 5, .id = 10 });
    try std.testing.expect(state.track(6));
    state.expectOutput(.{ .request_id = 6, .id = 11 });
    var content = [_]u8{ 'o', 'k' };
    const reply: schema.HistoryOutput = .{ .request_id = @enumFromInt(6), .id = 11, .truncated = true, .observed_bytes = 100, .content = &content };
    try std.testing.expect(state.applyOutput(reply));
    content[0] = 'x';
    try std.testing.expectEqualStrings("ok", state.outputSlice());
    try std.testing.expect(state.output_truncated);
    try std.testing.expect(state.fail(.{ .request_id = @enumFromInt(5), .code = .resource_limit, .message = "old failure" }));
    try std.testing.expect(state.output_phase == .ready);
    state.clearOutput();
    try std.testing.expect(!state.applyOutput(reply));
}

test "captured truncation blocks paste and unicode previews end at a codepoint boundary" {
    var state: State = .{};
    const command = "x" ** (max_command_bytes - 1) ++ "é";
    const entry: schema.HistoryEntry = .{ .id = 7, .pane_id = @enumFromInt(1), .started_at_ms = 0, .duration_ns = 0, .exit_code = null, .status = .completed, .command = command, .cwd = "", .workspace_path = "", .command_truncated = true };
    state.expect(1);
    try std.testing.expect(state.apply(1, &.{entry}));
    try std.testing.expect(state.commandAt(0) == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.slice()[0].commandSlice()));
    try std.testing.expectEqual(@as(u16, max_command_bytes - 1), state.slice()[0].command_len);
}

test "command storage exhaustion uses one correlated full-command fallback" {
    var state: State = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    const command = "x" ** schema.max_history_command_bytes;
    var entries: [14]schema.HistoryEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{ .id = index + 1, .pane_id = @enumFromInt(1), .started_at_ms = 0, .duration_ns = 0, .exit_code = 0, .status = .completed, .command = command, .cwd = "", .workspace_path = "" };
    }

    state.expect(1);
    try std.testing.expect(state.apply(1, &entries));
    try std.testing.expect(state.commandAt(13) == null);
    try std.testing.expect(state.track(2));
    state.expectFull(.{ .request_id = 2, .id = 14 });
    try std.testing.expect(!state.applyFull(3, entries[13..14]));
    try std.testing.expect(state.applyFull(2, entries[13..14]));
    try std.testing.expectEqualStrings(command, state.commandAt(13).?);
    try std.testing.expect(state.commandAt(12) == null);
    state.expect(4);
    try std.testing.expect(!state.applyFull(2, entries[13..14]));
    try std.testing.expect(state.commandAt(13) == null);
}
