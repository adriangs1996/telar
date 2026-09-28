//! The path picker's disposable state: the pane it inserts into, the pane's
//! directory when it opened, the root being browsed, and the newest page
//! of matches the runtime returned. Only the newest request may replace
//! the page; a bounded ring remembers older ids so their late failures are
//! recognised and dropped.

const core = @import("telar-core");
const std = @import("std");
const PathPickerMatch = @import("PathPickerMatch.zig");
const PathPickerState = @This();

/// Bytes the page keeps for all its paths; a longer page ends early.
pub const max_page_bytes = 16 * 1024;
pub const max_error_bytes = 128;
const tracked_requests = 32;

pub const Phase = enum {
    idle,
    loading,
    ready,
    failed,
};

revision: u64 = 0,
phase: Phase = .idle,
pane_id: core.PaneId = .invalid,
/// The pane's directory when the picker opened; inserted paths are
/// relative to it.
anchor: [core.max_cwd_bytes]u8 = undefined,
anchor_len: u16 = 0,
root: [core.max_cwd_bytes]u8 = undefined,
root_len: u16 = 0,
/// The next request rebuilds the runtime's index.
refresh: bool = false,
pending_request: u64 = 0,
requests: [tracked_requests]u64 = @splat(0),
next_slot: u8 = 0,
page_bytes: [max_page_bytes]u8 = undefined,
page_used: u16 = 0,
matches: [core.max_path_results]PathPickerMatch = undefined,
len: u8 = 0,
scanned: u32 = 0,
complete: bool = true,
truncated: bool = false,
error_text: [max_error_bytes]u8 = undefined,
error_len: u8 = 0,

/// Starts a picker over `directory` that inserts into `pane_id`.
///
/// ```zig
/// model.path_picker.begin(pane.id, pane.cwdSlice());
/// ```
pub fn begin(self: *PathPickerState, pane_id: core.PaneId, directory: []const u8) void {
    std.debug.assert(directory.len <= self.anchor.len);
    self.pane_id = pane_id;
    @memcpy(self.anchor[0..directory.len], directory);
    self.anchor_len = @intCast(directory.len);
    self.setRoot(directory);
    self.revision +%= 1;
}

/// Moves the picker to another root and empties the page; the next
/// request rebuilds the index there. Example: `model.path_picker.setRoot("/work/src");`
pub fn setRoot(self: *PathPickerState, directory: []const u8) void {
    std.debug.assert(directory.len <= self.root.len);
    @memcpy(self.root[0..directory.len], directory);
    self.root_len = @intCast(directory.len);
    self.refresh = true;
    self.len = 0;
    self.page_used = 0;
    self.scanned = 0;
    self.complete = true;
    self.truncated = false;
    self.error_len = 0;
    self.phase = .idle;
    self.revision +%= 1;
}

/// Closes the picker; late replies land into nothing.
pub fn close(self: *PathPickerState) void {
    self.phase = .idle;
    self.pending_request = 0;
    self.pane_id = .invalid;
    self.len = 0;
    self.page_used = 0;
    self.revision +%= 1;
}

pub fn rootSlice(self: *const PathPickerState) []const u8 {
    return self.root[0..self.root_len];
}

pub fn anchorSlice(self: *const PathPickerState) []const u8 {
    return self.anchor[0..self.anchor_len];
}

pub fn errorSlice(self: *const PathPickerState) []const u8 {
    return self.error_text[0..self.error_len];
}

pub fn slice(self: *const PathPickerState) []const PathPickerMatch {
    return self.matches[0..self.len];
}

/// The path of one match, relative to the root.
pub fn path(self: *const PathPickerState, match: *const PathPickerMatch) []const u8 {
    return self.page_bytes[match.offset..][0..match.len];
}

/// Makes `id` the request whose reply replaces the page.
///
/// ```zig
/// model.path_picker.expect(core.raw(request_id));
/// ```
pub fn expect(self: *PathPickerState, id: u64) void {
    self.requests[self.next_slot] = id;
    self.next_slot = (self.next_slot + 1) % tracked_requests;
    self.pending_request = id;
    self.refresh = false;
    self.phase = .loading;
    self.revision +%= 1;
}

/// Replaces the page with the newest reply; any other reply is dropped.
///
/// ```zig
/// _ = try model.path_picker.receive(results);
/// ```
pub fn receive(self: *PathPickerState, results: core.PathResultsView) !bool {
    const id = core.raw(results.request_id);
    if (id == 0 or id != self.pending_request or !std.mem.eql(
        u8,
        results.root,
        self.rootSlice(),
    )) {
        return false;
    }

    self.len = 0;
    self.page_used = 0;
    var storage: [core.max_path_query_bytes]u16 = undefined;
    var iterator = results.matches();
    while (try iterator.next(&storage)) |match| {
        if (!self.keep(match)) {
            break;
        }
    }

    self.scanned = results.scanned;
    self.complete = results.complete;
    self.truncated = results.truncated;
    self.error_len = 0;
    self.phase = .ready;
    if (results.complete) {
        self.pending_request = 0;
    }

    self.revision +%= 1;
    return true;
}

fn keep(self: *PathPickerState, match: core.PathMatch) bool {
    if (self.page_used + match.path.len > self.page_bytes.len) {
        return false;
    }

    const entry = &self.matches[self.len];
    entry.* = .{
        .offset = self.page_used,
        .len = @intCast(match.path.len),
        .kind = match.kind,
        .position_count = @intCast(match.positions.len),
    };
    @memcpy(entry.positions[0..match.positions.len], match.positions);
    @memcpy(self.page_bytes[self.page_used..][0..match.path.len], match.path);
    self.page_used += @intCast(match.path.len);
    self.len += 1;
    return true;
}

/// Shows a failure of the newest request; reports whether the id was ours.
///
/// ```zig
/// if (!model.path_picker.fail(failure)) try request_failure.failRuntimeRequest(client, failure);
/// ```
pub fn fail(self: *PathPickerState, failure: core.RequestFailed) bool {
    const id = core.raw(failure.request_id);
    if (id == 0 or std.mem.indexOfScalar(
        u64,
        &self.requests,
        id,
    ) == null) {
        return false;
    }

    if (id == self.pending_request) {
        self.pending_request = 0;
        self.phase = .failed;
        self.setError(failure.message);
    }

    return true;
}

/// Shows a local failure, such as a full request queue.
pub fn setError(self: *PathPickerState, message: []const u8) void {
    const len = @min(message.len, self.error_text.len);
    @memcpy(self.error_text[0..len], message[0..len]);
    self.error_len = @intCast(len);
    self.phase = .failed;
    self.revision +%= 1;
}

pub fn version(self: *const PathPickerState) u64 {
    return self.revision;
}

test "only the newest reply for the current root replaces the page" {
    var state: PathPickerState = .{};
    state.begin(@enumFromInt(3), "/work");
    state.expect(7);

    var buffer: [512]u8 = undefined;
    const encoded = try core.encodePathResults(&buffer, .{
        .request_id = @enumFromInt(7),
        .root = "/work",
        .scanned = 2,
        .matches = &.{.{
            .path = "src/main.zig",
            .kind = .file,
            .positions = &.{ 4, 5 },
        }},
    });
    const message = try core.decodeServer(encoded);
    try std.testing.expect(try state.receive(message.path_results));
    try std.testing.expectEqual(@as(usize, 1), state.slice().len);
    try std.testing.expectEqualStrings("src/main.zig", state.path(&state.slice()[0]));
    try std.testing.expectEqual(Phase.ready, state.phase);
    try std.testing.expect(!try state.receive(message.path_results));
}

test "late failures of older requests are recognised without replacing the page" {
    var state: PathPickerState = .{};
    state.begin(@enumFromInt(3), "/work");
    state.expect(7);
    state.expect(8);

    try std.testing.expect(state.fail(.{
        .request_id = @enumFromInt(7),
        .code = .resource_limit,
        .message = "busy",
    }));
    try std.testing.expectEqual(Phase.loading, state.phase);
    try std.testing.expect(state.fail(.{
        .request_id = @enumFromInt(8),
        .code = .permission_denied,
        .message = "the directory cannot be read",
    }));
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqualStrings("the directory cannot be read", state.errorSlice());
    try std.testing.expect(!state.fail(.{
        .request_id = @enumFromInt(99),
        .code = .internal,
        .message = "other",
    }));
}
