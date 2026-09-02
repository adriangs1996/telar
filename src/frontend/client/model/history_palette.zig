//! Bounded storage for the latest history-palette results. The palette only
//! shows the newest reply for the newest query, so stale replies are ignored
//! by request id instead of queued.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_entries = 16;
pub const max_command_bytes = 512;
pub const max_entry_cwd_bytes = 64;

pub const Entry = struct {
    id: u64 = 0,
    status: schema.HistoryStatus = .completed,
    author: schema.HistoryAuthor = .human,
    exit_code: ?i32 = null,
    command: [max_command_bytes]u8 = undefined,
    command_len: u16 = 0,
    cwd: [max_entry_cwd_bytes]u8 = undefined,
    cwd_len: u8 = 0,

    pub fn commandSlice(entry: *const Entry) []const u8 {
        return entry.command[0..entry.command_len];
    }

    pub fn cwdSlice(entry: *const Entry) []const u8 {
        return entry.cwd[0..entry.cwd_len];
    }
};

pub const State = struct {
    revision: u64 = 0,
    pending_request: u64 = 0,
    entries: [max_entries]Entry = undefined,
    len: u8 = 0,

    /// Clears previous results when the palette opens.
    ///
    /// ```zig
    /// model.history_palette.begin();
    /// ```
    pub fn begin(state: *State) void {
        state.len = 0;
        state.pending_request = 0;
        state.revision +%= 1;
    }

    /// Records the request whose reply the palette is waiting for. Older
    /// in-flight replies become stale immediately.
    ///
    /// ```zig
    /// model.history_palette.expect(schema.id.raw(request_id));
    /// ```
    pub fn expect(state: *State, request_id: u64) void {
        state.pending_request = request_id;
    }

    /// Copies one reply's entries into bounded storage. Replies for any other
    /// request than the awaited one are ignored.
    ///
    /// ```zig
    /// _ = model.history_palette.apply(request_id, decoded_entries);
    /// ```
    pub fn apply(state: *State, request_id: u64, entries: []const schema.HistoryEntry) bool {
        if (request_id != state.pending_request) {
            return false;
        }

        state.len = 0;
        for (entries) |*entry| {
            if (state.len == max_entries) {
                break;
            }

            var stored: Entry = .{
                .id = entry.id,
                .status = entry.status,
                .author = entry.author,
                .exit_code = entry.exit_code,
            };
            stored.command_len = copyBounded(&stored.command, entry.command);
            stored.cwd_len = @intCast(copyBounded(&stored.cwd, entry.cwd));
            state.entries[state.len] = stored;
            state.len += 1;
        }

        state.revision +%= 1;
        return true;
    }

    pub fn slice(state: *const State) []const Entry {
        return state.entries[0..state.len];
    }

    pub fn version(state: *const State) u64 {
        return state.revision;
    }
};

fn copyBounded(buffer: []u8, source: []const u8) u16 {
    const len = @min(buffer.len, source.len);
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
