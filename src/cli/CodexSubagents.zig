//! The subagents a Codex thread started and has not seen complete, read
//! from its rollout. Codex lists them in no hook payload: the thread's rollout
//! records one `SubAgentActivity` item when `spawn_agent` starts a child and
//! another when the child completes, keyed by the child's thread id, which
//! is the `agent_id` its own hooks carry.

const std = @import("std");

const privatefile = @import("privatefile");

const native = std.c;
const Inode = privatefile.Inode;
const CodexSubagents = @This();

/// Children tracked at once; more are counted as this many.
pub const max_tracked = 32;
/// Longest thread id kept; Codex uses 36-byte UUIDs.
pub const max_id_bytes = 64;

const chunk_bytes = 64 * 1024;
/// A `SubAgentActivity` item is a few hundred bytes; a longer one is not an
/// activity record and is skipped.
const max_item_bytes = 1024;
const marker = "\"item\":{\"type\":\"SubAgentActivity\"";
const kind_key = "\"kind\":\"";
const thread_key = "\"agent_thread_id\":\"";

/// Thread ids of started children without a completion.
ids: [max_tracked][max_id_bytes]u8 = undefined,
lens: [max_tracked]u8 = undefined,
count: usize = 0,

/// Counts the running children other than `finished`, the child whose
/// `SubagentStop` is being reported and whose completion may not be
/// written yet.
///
/// ```zig
/// const left = running.countExcept(input.agent_id orelse "");
/// ```
pub fn countExcept(self: *const CodexSubagents, finished: []const u8) usize {
    if (self.find(finished) != null) {
        return self.count - 1;
    }

    return self.count;
}

fn find(self: *const CodexSubagents, id: []const u8) ?usize {
    for (0..self.count) |index| {
        if (std.mem.eql(u8, self.ids[index][0..self.lens[index]], id)) {
            return index;
        }
    }

    return null;
}

fn start(self: *CodexSubagents, id: []const u8) void {
    if (self.find(id) != null or self.count == max_tracked) {
        return;
    }

    @memcpy(self.ids[self.count][0..id.len], id);
    self.lens[self.count] = @intCast(id.len);
    self.count += 1;
}

fn complete(self: *CodexSubagents, id: []const u8) void {
    const index = self.find(id) orelse return;
    self.count -= 1;
    self.ids[index] = self.ids[self.count];
    self.lens[index] = self.lens[self.count];
}

// Applies one activity item, the bytes from `marker` to its closing brace.
fn apply(self: *CodexSubagents, item: []const u8) void {
    const kind = value(item, kind_key) orelse return;
    const id = value(item, thread_key) orelse return;
    if (id.len == 0 or id.len > max_id_bytes) {
        return;
    }

    if (std.mem.eql(u8, kind, "started")) {
        self.start(id);
    } else if (std.mem.eql(u8, kind, "completed")) {
        self.complete(id);
    }
}

/// Applies every whole activity item in `bytes` and returns how many
/// leading bytes were consumed; the rest may hold an item cut by the
/// chunk end and must be scanned again with more input after it.
///
/// ```zig
/// const consumed = running.scan(window, at_end);
/// ```
pub fn scan(self: *CodexSubagents, bytes: []const u8, at_end: bool) usize {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, marker)) |start_index| {
        const limit = @min(bytes.len, start_index + max_item_bytes);
        const close = std.mem.indexOfScalarPos(u8, bytes[0..limit], start_index + marker.len, '}') orelse {
            if (limit == bytes.len and !at_end) {
                return start_index;
            }

            cursor = start_index + marker.len;
            continue;
        };

        self.apply(bytes[start_index..close]);
        cursor = close + 1;
    }

    if (at_end) {
        return bytes.len;
    }

    // Keep a tail that may hold the start of a marker.
    return @max(cursor, bytes.len -| (marker.len - 1));
}
/// Reads the rollout at `path` and returns the children it started without
/// a completion. A missing, unsafe or unreadable file yields none, so the
/// hook falls back to its plain mapping.
///
/// ```zig
/// const running = CodexSubagents.read(io, input.transcript_path);
/// ```
pub fn read(io: std.Io, path: []const u8) CodexSubagents {
    var running: CodexSubagents = .{};
    if (path.len == 0 or path[0] != '/' or !std.mem.endsWith(u8, path, ".jsonl")) {
        return running;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{path}) catch return running;
    const fd = native.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        return running;
    }

    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);

    // A FIFO or another user's file is never a rollout this agent wrote.
    const inode = Inode.fromDescriptor(fd) catch return running;
    if (inode.kind() != .regular or inode.owner != native.getuid()) {
        return running;
    }

    var window: [chunk_bytes]u8 = undefined;
    var held: usize = 0;
    var offset: u64 = 0;
    while (true) {
        const received = file.readPositionalAll(io, window[held..], offset) catch return .{};
        offset += received;
        const filled = held + received;
        const at_end = filled < window.len;
        const consumed = running.scan(window[0..filled], at_end);
        if (at_end) {
            return running;
        }

        held = filled - consumed;
        std.mem.copyForwards(u8, window[0..held], window[consumed..filled]);
    }
}

fn value(item: []const u8, key: []const u8) ?[]const u8 {
    const from = (std.mem.indexOf(u8, item, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, item, from, '"') orelse return null;
    return item[from..end];
}

const started_a = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"SubAgentActivity\",\"id\":\"call_a\",\"kind\":\"started\",\"agent_thread_id\":\"thread-a\",\"agent_path\":\"/root/a\"}}}\n";
const started_b = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"SubAgentActivity\",\"id\":\"call_b\",\"kind\":\"started\",\"agent_thread_id\":\"thread-b\",\"agent_path\":\"/root/b\"}}}\n";
const completed_a = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"type\":\"SubAgentActivity\",\"id\":\"subagent-completed-x\",\"kind\":\"completed\",\"agent_thread_id\":\"thread-a\",\"agent_path\":\"/root/a\"}}}\n";

test "started children without a completion are running" {
    var running: CodexSubagents = .{};
    const bytes = started_a ++ started_b ++ completed_a ++ started_b;
    try std.testing.expectEqual(bytes.len, running.scan(bytes, true));
    try std.testing.expectEqual(@as(usize, 1), running.count);
    try std.testing.expectEqual(@as(usize, 1), running.countExcept("thread-a"));
    try std.testing.expectEqual(@as(usize, 0), running.countExcept("thread-b"));
}

test "a quoted marker inside message text is not an activity" {
    var running: CodexSubagents = .{};
    const quoted = "{\"text\":\"\\\"item\\\":{\\\"type\\\":\\\"SubAgentActivity\\\",\\\"kind\\\":\\\"started\\\",\\\"agent_thread_id\\\":\\\"fake\\\"}\"}\n";
    _ = running.scan(quoted, true);
    try std.testing.expectEqual(@as(usize, 0), running.count);
}

test "an item cut by the chunk end is scanned again with the rest" {
    var running: CodexSubagents = .{};
    const bytes = started_a ++ started_b;
    const cut = started_a.len + 70;
    const consumed = running.scan(bytes[0..cut], false);
    try std.testing.expectEqual(@as(usize, 1), running.count);
    try std.testing.expect(consumed <= cut);
    _ = running.scan(bytes[consumed..], true);
    try std.testing.expectEqual(@as(usize, 2), running.count);
}

test "a rollout file is read across chunks and unsafe paths yield nothing" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    // Pad the rollout past one window so the second start straddles chunks.
    var content: [chunk_bytes + 4096]u8 = undefined;
    const padding = chunk_bytes - started_a.len - 60;
    @memcpy(content[0..started_a.len], started_a);
    @memset(content[started_a.len .. started_a.len + padding], ' ');
    content[started_a.len + padding - 1] = '\n';
    const tail_start = started_a.len + padding;
    @memcpy(content[tail_start .. tail_start + started_b.len], started_b);
    const len = tail_start + started_b.len;
    try temp.dir.writeFile(io, .{ .sub_path = "rollout.jsonl", .data = content[0..len] });

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/rollout.jsonl", .{directory_buffer[0..directory_len]});
    try std.testing.expectEqual(@as(usize, 2), read(io, path).count);

    try std.testing.expectEqual(@as(usize, 0), read(io, "rollout.jsonl").count);
    try std.testing.expectEqual(@as(usize, 0), read(io, "/nonexistent/telar/rollout.jsonl").count);
}
