const Decoder = @import("../Decoder.zig");
const HistoryStatsTop = @import("HistoryStatsTop.zig");
const types = @import("../types.zig");
const HistoryStatsTopIterator = @This();

decoder: Decoder,
remaining: u8,

pub fn next(self: *HistoryStatsTopIterator) !?HistoryStatsTop {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    const count = try self.decoder.readInt(u64);
    const command = try self.decoder.readSized16();
    if (command.len == 0 or command.len > types.max_history_command_bytes) {
        return error.InvalidByteString;
    }
    return .{ .count = count, .command = command };
}
