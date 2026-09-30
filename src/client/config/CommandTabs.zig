//! The command tabs a configuration generation's actions open. An action
//! holds a `CommandTabRef` into this table instead of the argv, so the
//! Action union, which bindings, bar components and callback results all
//! hold, stays small. Every row packs its argv and label into one shared
//! byte pool, so a short command takes its own bytes, not the 4 KiB an argv
//! may reach.
//!
//! The rows the configuration opens while it loads (bindings, static bar
//! components) are fixed for the generation. What renders and callbacks
//! return later goes into the recent rows after them, which are cleared
//! whole when they fill: a render runs again on its next tick and keeps its
//! commands anew, and a reference to a cleared row names nothing.
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const CommandTabs = @This();

/// Bytes the fixed and recent rows share; the fixed ones may take all but
/// `recent_reserve`, room for a full keymap of 256 command tabs of 256
/// bytes.
pub const pool_bytes = 96 * 1024;
/// Bytes always left to the recent rows: three commands of the largest argv.
const recent_reserve = 16 * 1024;
/// Rows of both kinds: the bindings and static components of the base
/// configuration and of the selected profile, and what renders keep.
pub const max_rows = 1024;
pub const limit = core.Limit.declare("config.command_tab_bytes", "command tab bytes", pool_bytes - recent_reserve);
/// A row's header: its argument count and its label length.
const header_bytes = 2;
const length_bytes = @sizeOf(u16);
/// The largest row: a header, 32 argument lengths, 4096 argv bytes and a label.
const max_row_bytes = header_bytes + length_bytes * data.CommandTab.max_arguments + data.CommandTab.max_command_bytes + data.CommandTab.max_label_bytes;

comptime {
    std.debug.assert(recent_reserve >= 3 * max_row_bytes);
}

bytes: [pool_bytes]u8 = undefined,
used: u32 = 0,
/// Where each row starts in `bytes`.
offsets: [max_rows]u32 = undefined,
count: u16 = 0,
/// Rows and bytes the configuration fixed while it loaded; the recent rows
/// follow them.
fixed_rows: u16 = 0,
fixed_bytes: u32 = 0,
sealed: bool = false,
/// Advances each time the recent rows are cleared.
epoch: u32 = 1,

/// Keeps `command` and returns the reference that names it in the
/// generation `number`, sharing an equal row. Before `seal` the row is fixed; a full fixed pool fails with
/// `TooManyCommandTabs`. After it the row is recent, and full recent rows
/// are cleared to make room, so it never fails.
///
/// ```zig
/// const reference = try generation.snapshot.command_tabs.add(generation.number, &command);
/// ```
pub fn add(self: *CommandTabs, number: u64, command: *const data.CommandTab) !data.CommandTabRef {
    var encoded: [max_row_bytes]u8 = undefined;
    const row = encode(command, &encoded);
    for (0..self.count) |id| {
        if (std.mem.eql(u8, self.rowBytes(@intCast(id)), row)) {
            return self.reference(number, @intCast(id));
        }
    }

    if (!self.sealed) {
        if (self.used + row.len > pool_bytes - recent_reserve or self.count == max_rows) {
            return error.TooManyCommandTabs;
        }

        return self.reference(number, self.append(row));
    }

    if (self.used + row.len > pool_bytes or self.count == max_rows) {
        self.used = self.fixed_bytes;
        self.count = self.fixed_rows;
        self.epoch +%= 1;
        if (self.epoch == 0) {
            self.epoch = 1;
        }
    }

    return self.reference(number, self.append(row));
}

/// Ends loading: the rows kept so far stay for the generation and later
/// ones are recent.
/// Example: `generation.snapshot.command_tabs.seal();`
pub fn seal(self: *CommandTabs) void {
    self.sealed = true;
    self.fixed_rows = self.count;
    self.fixed_bytes = self.used;
}

/// Writes into `command` the command `ref` names in the generation
/// `number`; false when it belongs to another generation or its recent row
/// was cleared.
///
/// ```zig
/// var command: data.CommandTab = undefined;
/// if (!tabs.find(generation.number, reference, &command)) return;
/// ```
pub fn find(self: *const CommandTabs, number: u64, ref: data.CommandTabRef, command: *data.CommandTab) bool {
    if (ref.generation != number) {
        return false;
    }

    return self.load(ref, command);
}

/// `find` for a reader that already holds this table's generation, such
/// as a configuration query.
/// Example: `if (!snapshot.command_tabs.load(reference, &command)) return error.BindingNotFound;`
pub fn load(self: *const CommandTabs, ref: data.CommandTabRef, command: *data.CommandTab) bool {
    if (ref.id >= self.count) {
        return false;
    }

    const expected: u32 = if (ref.id < self.fixed_rows or !self.sealed) 0 else self.epoch;
    if (ref.epoch != expected) {
        return false;
    }

    decode(self.rowBytes(ref.id), command);
    return true;
}

fn reference(self: *const CommandTabs, number: u64, id: u16) data.CommandTabRef {
    return .{
        .generation = number,
        .epoch = if (id < self.fixed_rows or !self.sealed) 0 else self.epoch,
        .id = id,
    };
}

fn append(self: *CommandTabs, row: []const u8) u16 {
    const id = self.count;
    self.offsets[id] = self.used;
    @memcpy(self.bytes[self.used..][0..row.len], row);
    self.used += @intCast(row.len);
    self.count += 1;
    return id;
}

fn rowBytes(self: *const CommandTabs, id: u16) []const u8 {
    const start = self.offsets[id];
    const end = if (id + 1 < self.count) self.offsets[id + 1] else self.used;
    return self.bytes[start..end];
}

/// A row: argument count, label length, each argument's length, the argv
/// bytes and the label.
fn encode(command: *const data.CommandTab, buffer: *[max_row_bytes]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const label = command.label_storage[0..command.label_len];
    // The buffer holds the largest row, so no write fails.
    writer.writeByte(command.argument_count) catch unreachable;
    writer.writeByte(command.label_len) catch unreachable;
    for (command.argument_lens[0..command.argument_count]) |len| {
        writer.writeInt(u16, len, .little) catch unreachable;
    }

    for (0..command.argument_count) |index| {
        writer.writeAll(command.argument(index)) catch unreachable;
    }

    writer.writeAll(label) catch unreachable;
    return writer.buffered();
}

fn decode(row: []const u8, command: *data.CommandTab) void {
    command.argument_count = row[0];
    command.label_len = row[1];
    var offset: usize = header_bytes;
    var argv_bytes: usize = 0;
    for (0..command.argument_count) |index| {
        command.argument_lens[index] = std.mem.readInt(u16, row[offset..][0..length_bytes], .little);
        argv_bytes += command.argument_lens[index];
        offset += length_bytes;
    }

    @memcpy(command.argument_storage[0..argv_bytes], row[offset..][0..argv_bytes]);
    offset += argv_bytes;
    @memcpy(command.label_storage[0..command.label_len], row[offset..][0..command.label_len]);
}

test "fixed rows stay, equal commands share a row and recent rows clear whole when full" {
    const tabs = try std.testing.allocator.create(CommandTabs);
    defer std.testing.allocator.destroy(tabs);
    tabs.* = .{};

    const bound = try data.CommandTab.init(&.{ "lazygit", "-p" }, "git");
    const fixed = try tabs.add(1, &bound);
    try std.testing.expectEqual(@as(u32, 0), fixed.epoch);
    try std.testing.expectEqual(fixed.id, (try tabs.add(1, &bound)).id);
    tabs.seal();

    var number: [8]u8 = undefined;
    var first: ?data.CommandTabRef = null;
    var cleared = false;
    for (0..4 * max_rows) |index| {
        const text = std.fmt.bufPrint(&number, "{d}", .{index}) catch unreachable;
        const pr = try data.CommandTab.init(&.{ "gh", "pr", "checkout", text }, "");
        const recent = try tabs.add(1, &pr);
        first = first orelse recent;
        cleared = cleared or recent.epoch != first.?.epoch;

        var command: data.CommandTab = undefined;
        try std.testing.expect(tabs.find(1, recent, &command));
        try std.testing.expectEqualStrings(text, command.argument(3));
    }

    try std.testing.expect(cleared);
    var command: data.CommandTab = undefined;
    try std.testing.expect(!tabs.find(1, first.?, &command));
    try std.testing.expect(!tabs.find(2, .{ .generation = 1, .id = fixed.id }, &command));
    try std.testing.expect(tabs.find(1, .{ .generation = 1, .id = fixed.id }, &command));
    try std.testing.expectEqualStrings("git", command.label());
    try std.testing.expectEqualStrings("-p", command.argument(1));
}

test "the fixed rows stop at their share of the pool and leave the recent reserve" {
    const tabs = try std.testing.allocator.create(CommandTabs);
    defer std.testing.allocator.destroy(tabs);
    tabs.* = .{};

    var script: [data.CommandTab.max_command_bytes - 16]u8 = undefined;
    @memset(&script, 'a');
    var kept_rows: usize = 0;
    var full = false;
    while (!full) {
        _ = std.fmt.bufPrint(script[0..8], "{d:0>8}", .{kept_rows}) catch unreachable;
        const command = try data.CommandTab.init(&.{ "sh", "-c", &script }, "");
        if (tabs.add(1, &command)) |_| {
            kept_rows += 1;
        } else |err| {
            try std.testing.expectEqual(error.TooManyCommandTabs, err);
            full = true;
        }
    }

    try std.testing.expect(kept_rows >= (pool_bytes - recent_reserve) / max_row_bytes);
    try std.testing.expect(tabs.used <= pool_bytes - recent_reserve);
}
