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
