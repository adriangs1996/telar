const core = @import("telar-core");
const Entry = @import("Entry.zig");
const Storage = @import("Storage.zig");
const std = @import("std");
const history_palette = @import("history_palette.zig");
const State = @This();

/// Rows one palette page shows and asks the runtime for; older and newer
/// pages page through the rest. Below `core.max_history_results`, which
/// bounds any one reply.
pub const page_entries = 100;

comptime {
    std.debug.assert(page_entries <= core.max_history_results);
    std.debug.assert(page_entries <= std.math.maxInt(u8));
}

revision: u64 = 0,
pending_request: u64 = 0,
entries: [page_entries]Entry = undefined,
len: u8 = 0,
phase: enum { idle, loading, ready, failed } = .idle,
has_page: bool = false,
now_ms: i64 = 0,
/// Minutes east of UTC when the page landed; rows and day groups use it.
utc_offset_min: i16 = 0,
enter_runs: bool = false,
match_fuzzy: bool = true,
effective_scope: core.HistoryScope = .global,
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
pub fn prepare(self: *State, gpa: std.mem.Allocator) !void {
    if (self.storage != null) {
        return;
    }

    self.storage = try gpa.create(Storage);
    self.allocator = gpa;
}

/// Releases storage after all client callbacks have stopped.
/// Example: `defer state.deinit();`.
pub fn deinit(self: *State) void {
    if (self.storage) |storage| {
        self.allocator.?.destroy(storage);
        self.storage = null;
    }
}

/// Clears previous results when the palette opens.
///
/// ```zig
/// model.history_palette.begin();
/// ```
pub fn begin(self: *State) void {
    self.len = 0;
    self.pending_request = 0;
    self.phase = .idle;
    self.has_page = false;
    self.commands_len = 0;
    self.clearOutput();
    self.error_len = 0;
    self.page_offset = 0;
    self.pending_offset = 0;
    self.snapshot_id = 0;
    self.has_more = false;
    self.full_id = 0;
    self.full_request = 0;
    self.full_len = 0;
    self.revision +%= 1;
}

/// Starts a search generation without reusing the previous insertion boundary.
/// Example: `state.restartQuery();`.
pub fn restartQuery(self: *State) void {
    self.snapshot_id = 0;
    self.pending_offset = 0;
}

pub fn configure(self: *State, options: struct { enter_runs: bool, match_fuzzy: bool }) void {
    self.enter_runs = options.enter_runs;
    self.match_fuzzy = options.match_fuzzy;
}

pub const PageResult = @import("PageResult.zig");

/// Reserves correlation and replaces actionable rows in one transition.
/// Example: `if (!state.beginPageRequest(id, .global)) return;`.
pub fn beginPageRequest(self: *State, id: u64, scope: core.HistoryScope) bool {
    if (id == 0 or !self.track(id)) {
        self.rejectQuery();
        return false;
    }

    self.effective_scope = scope;
    self.expect(id);
    return true;
}

/// Commits entries, pagination and display time under a single revision.
/// Example: `_ = state.acceptPageResult(page);`.
pub fn acceptPageResult(self: *State, result: PageResult) bool {
    if (!self.applyEntries(result.request_id, result.entries)) {
        return false;
    }

    self.snapshot_id = result.snapshot_id;
    self.has_page = true;
    self.has_more = result.has_more;
    self.now_ms = result.now_ms;
    self.utc_offset_min = result.utc_offset_min;
    self.pending_request = 0;
    self.revision +%= 1;
    return true;
}

/// Keeps the previous page, including an empty result, visible during refresh.
/// Example: `if (state.initialLoading()) drawSearching();`.
pub fn initialLoading(self: *const State) bool {
    return self.phase == .loading and !self.has_page;
}

/// Plans an adjacent bounded page; the visible page remains until its reply lands.
/// Example: `if (state.page(.older)) requestPage();`.
pub fn page(self: *State, direction: enum { older, newer }) bool {
    if (self.phase != .ready or self.len == 0) {
        return false;
    }

    switch (direction) {
        .older => {
            if (!self.has_more) {
                return false;
            }

            self.pending_offset = self.page_offset +| self.len;
        },
        .newer => {
            if (self.page_offset == 0) {
                return false;
            }

            self.pending_offset = self.page_offset -| page_entries;
        },
    }

    return true;
}

/// Prevents submitting previous results when no new request can be admitted.
/// Example: `state.rejectQuery();`.
fn rejectQuery(self: *State) void {
    self.phase = .failed;
    self.pending_request = 0;
}

pub fn expectFull(self: *State, request: struct { request_id: u64, id: u64 }) void {
    self.full_request = request.request_id;
    self.full_id = request.id;
    self.full_len = 0;
}

pub fn expectDelete(self: *State, request_id: u64) void {
    self.delete_request = request_id;
}

/// Retires deletion acknowledgements without letting an old one refresh a new search.
/// Example: `if (state.pruned(request_id)) refresh();`.
pub fn pruned(self: *State, request_id: u64) bool {
    _ = self.retire(request_id);
    if (request_id == 0 or request_id != self.delete_request) {
        return false;
    }

    self.delete_request = 0;
    return true;
}

/// Records the request whose reply the palette is waiting for. Older
/// in-flight replies become stale immediately.
///
/// ```zig
/// Internal half of beginPageRequest; never exposed independently.
/// ```
fn expect(self: *State, request_id: u64) void {
    self.pending_request = request_id;
    self.phase = .loading;
    self.full_id = 0;
    self.full_request = 0;
    self.full_len = 0;
    self.error_len = 0;
    self.clearOutput();
    self.revision +%= 1;
}

/// Copies one reply's entries into bounded storage. Replies for any other
/// request than the awaited one are ignored.
///
/// ```zig
/// Internal half of acceptPageResult; metadata commits before publication.
/// ```
fn applyEntries(self: *State, request_id: u64, entries: []const core.HistoryEntry) bool {
    _ = self.retire(request_id);
    if (request_id == 0 or request_id != self.pending_request or self.phase != .loading) {
        return false;
    }

    self.len = 0;
    self.commands_len = 0;
    for (entries) |*entry| {
        if (self.len == page_entries) {
            break;
        }

        var stored: Entry = .{
            .id = entry.id,
            .status = entry.status,
            .author = entry.author,
            .origin = entry.origin,
            .exit_code = entry.exit_code,
            .pane_id = entry.pane_id,
            .started_at_ms = entry.started_at_ms,
            .duration_ns = entry.duration_ns,
            .captured_truncated = entry.command_truncated,
        };
        stored.provider_len = @intCast(history_palette.copyBounded(&stored.provider, entry.provider));
        if (entry.command.len <= history_palette.max_command_bytes) {
            stored.command_complete = true;
        } else if (self.storage) |storage| {
            if (entry.command.len <= storage.commands.len - self.commands_len) {
                stored.full_offset = self.commands_len;
                stored.full_len = @intCast(entry.command.len);
                @memcpy(storage.commands[self.commands_len..][0..entry.command.len], entry.command);
                self.commands_len += stored.full_len;
                stored.command_complete = true;
            }
        }

        stored.command_len = history_palette.copyBounded(&stored.command, entry.command);
        stored.cwd_len = @intCast(history_palette.copyBounded(&stored.cwd, entry.cwd));
        self.entries[self.len] = stored;
        self.len += 1;
    }

    self.phase = .ready;
    self.page_offset = self.pending_offset;
    return true;
}

/// Returns the full command only when the current reply owns every byte.
/// Example: `const command = state.commandAt(selection) orelse return;`.
pub fn commandAt(self: *const State, index: u16) ?[]const u8 {
    if (self.phase != .ready or index >= self.len) {
        return null;
    }

    const entry = &self.entries[index];
    if (entry.captured_truncated) {
        return null;
    }

    if (self.full_id == entry.id and self.full_len != 0) {
        return self.storage.?.selected_command[0..self.full_len];
    }

    if (!entry.command_complete) {
        return null;
    }

    if (entry.full_len == 0) {
        return entry.commandSlice();
    }

    return self.storage.?.commands[entry.full_offset..][0..entry.full_len];
}

/// Invalidates a closed inspector without accepting late output.
/// Example: `state.clearOutput();`.
pub fn clearOutput(self: *State) void {
    self.output_request = 0;
    self.output_id = 0;
    self.output_len = 0;
    self.output_phase = .idle;
    self.output_truncated = false;
}

/// Associates one bounded output read with its exact entry.
/// Example: `state.expectOutput(.{ .request_id = 7, .id = 3 });`.
pub fn expectOutput(self: *State, request: struct { request_id: u64, id: u64 }) void {
    self.clearOutput();
    self.output_request = request.request_id;
    self.output_id = request.id;
    self.output_phase = .loading;
    self.revision +%= 1;
}

/// Owns output before the receive buffer is reused; stale selections are ignored.
/// Example: `_ = state.applyOutput(reply);`.
pub fn applyOutput(self: *State, reply: core.HistoryOutput) bool {
    _ = self.retire(core.raw(reply.request_id));
    if (self.output_request == 0 or core.raw(reply.request_id) != self.output_request or reply.id != self.output_id) {
        return false;
    }

    const storage = self.storage orelse return false;
    // The tail is raw VT bytes; the inspector shows readable text only.
    const text = core.plainText(reply.content, &storage.output);
    self.output_len = @intCast(text.len);
    self.output_truncated = reply.truncated or reply.content.len > storage.output.len;
    self.output_phase = .ready;
    self.revision +%= 1;
    return true;
}

/// Keeps observation failures local to their query or inspector.
/// Example: `_ = state.fail(reply);`.
pub fn fail(self: *State, failure: core.RequestFailed) bool {
    const request = core.raw(failure.request_id);
    const owned = self.retire(request);
    if (request == self.pending_request and request != 0) {
        self.phase = .failed;
    } else if (request == self.output_request and request != 0) {
        self.output_phase = .failed;
    } else if (request == self.delete_request and request != 0) {
        self.delete_request = 0;
    } else if (request == self.full_request and request != 0) {
        self.full_request = 0;
    } else {
        return owned;
    }

    self.setError(failure.message);
    return true;
}

/// Records a local actionable error without closing the history browser.
/// Example: `state.setError("Command unavailable");`.
pub fn setError(self: *State, message: []const u8) void {
    self.error_len = @intCast(history_palette.copyBounded(&self.error_text, message));
    self.revision +%= 1;
}

pub fn errorSlice(self: *const State) []const u8 {
    return self.error_text[0..self.error_len];
}

pub fn outputSlice(self: *const State) []const u8 {
    const storage = self.storage orelse return "";
    return storage.output[0..self.output_len];
}

pub fn outputHint(self: *const State) []const u8 {
    return switch (self.output_phase) {
        .idle => "No captured output",
        .loading => "Loading captured output...",
        .failed => "Could not read captured output",
        .ready => if (self.output_len == 0) "No captured output" else if (self.output_truncated) "Captured output (truncated)" else "Captured output",
    };
}

/// Loads one complete command when the page's shared storage quota was exhausted.
/// Example: `_ = state.applyFull(reply_id, entries);`.
pub fn applyFull(self: *State, request_id: u64, entries: []const core.HistoryEntry) bool {
    if (request_id == 0 or request_id != self.full_request) {
        return false;
    }

    _ = self.retire(request_id);
    const storage = self.storage orelse return false;
    if (entries.len != 1 or entries[0].id != self.full_id or entries[0].command_truncated or entries[0].command.len > storage.selected_command.len) {
        self.setError("The selected command is no longer available");
        self.full_request = 0;
        return true;
    }

    const command = entries[0].command;
    @memcpy(storage.selected_command[0..command.len], command);
    self.full_len = @intCast(command.len);
    self.full_request = 0;
    self.error_len = 0;
    self.revision +%= 1;
    return true;
}

/// Reserves correlation before a request enters the asynchronous outbox.
/// Example: `if (!state.track(request_id)) return;`.
pub fn track(self: *State, request_id: u64) bool {
    for (&self.requests) |*pending| {
        if (pending.* == 0) {
            pending.* = request_id;
            return true;
        }
    }

    self.setError("History is busy; retry the search");
    return false;
}

/// Releases a completed request even when its visible state was replaced.
/// Example: `_ = state.retire(request_id);`.
pub fn retire(self: *State, request_id: u64) bool {
    if (request_id == 0) {
        return false;
    }

    for (&self.requests) |*pending| {
        if (pending.* == request_id) {
            pending.* = 0;
            return true;
        }
    }

    return false;
}

pub fn slice(self: *const State) []const Entry {
    return self.entries[0..self.len];
}

pub fn version(self: *const State) u64 {
    return self.revision;
}
