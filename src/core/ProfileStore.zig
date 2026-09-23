const std = @import("std");
const profiling = @import("profiling.zig");
const Counters = @import("ProfileCounters.zig");
const Store = @This();

claimed: std.atomic.Value(usize) = .init(0),
banks: [profiling.max_threads]Counters = @splat(.{}),

/// Each thread registers once; exhausted capacity drops that thread's data.
/// Example: `const counters = store.register(thread_id);`
pub fn register(self: *Store, thread: u64) ?*Counters {
    const index = self.claimed.fetchAdd(1, .monotonic);
    if (index >= self.banks.len) {
        return null;
    }
    self.banks[index].thread = thread;
    return &self.banks[index];
}

/// Call only after every producer has joined. Example: `try store.dump(io, directory);`
pub fn dump(self: *const Store, io: std.Io, directory: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{d}.profile.jsonl", .{ directory, std.c.getpid() });
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try self.write(&writer.interface);
    try writer.interface.flush();
}

/// Serializes quiescent banks for the shutdown dump.
fn write(self: *const Store, writer: *std.Io.Writer) !void {
    const claimed = self.claimed.load(.monotonic);
    try writer.print("{{\"type\":\"profile\",\"catalog\":{d},\"counts_enabled\":{},\"timing_enabled\":{},\"threads\":{d},\"dropped_threads\":{d},\"storage_bytes\":{d}}}\n", .{ profiling.catalog_version, profiling.enabled, profiling.timing_enabled, @min(claimed, self.banks.len), claimed -| self.banks.len, @sizeOf(Store) });
    for (self.banks[0..@min(claimed, self.banks.len)]) |*bank| {
        try bank.write(writer);
    }
}

test "profile thread banks are bounded and dump errors propagate" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    for (0..profiling.max_threads) |index| {
        const bank = store.register(index).?;
        bank.add(.gui_draw, 1);
    }
    try std.testing.expect(store.register(999) == null);
    try std.testing.expectEqual(@as(u64, 1), store.banks[0].values[@intFromEnum(profiling.Metric.gui_draw)]);
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, store.write(&writer));
}

test "concurrent writers receive disjoint aligned banks and joined output is complete" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| {
        thread.join();
    };
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, countOnThread, .{ store, index });
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
    started = 0;
    try std.testing.expectEqual(@as(usize, threads.len), store.claimed.load(.monotonic));
    var identities: u64 = 0;
    for (store.banks[0..threads.len]) |*bank| {
        try std.testing.expectEqual(@as(u64, 1000), bank.values[@intFromEnum(profiling.Metric.gui_draw)]);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bank) % std.atomic.cache_line);
        identities |= @as(u64, 1) << @intCast(bank.thread);
    }
    try std.testing.expectEqual(@as(u64, 255), identities);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try store.write(&output.writer);
    var rows = std.mem.tokenizeScalar(u8, output.written(), '\n');
    var count: usize = 0;
    while (rows.next()) |row| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, row, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.contains("type"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1 + threads.len * (std.enums.values(profiling.Metric).len + std.enums.values(profiling.Phase).len)), count);
}

fn countOnThread(self: *Store, identity: usize) void {
    const bank = self.register(identity).?;
    for (0..1000) |_| {
        bank.add(.gui_draw, 1);
    }
}
