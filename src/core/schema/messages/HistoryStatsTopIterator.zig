const HistoryStatsTopIterator = @This();
const wire = @import("../wire.zig");
const HistoryStatsTop = @import("HistoryStatsTop.zig");
const types = @import("../types.zig");
decoder: wire.Decoder,
remaining: u8,

pub fn next(iterator: *HistoryStatsTopIterator) !?HistoryStatsTop {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const count = try iterator.decoder.readInt(u64);
    const command = try iterator.decoder.readSized16();
    if (command.len == 0 or command.len > types.max_history_command_bytes) {
        return error.InvalidByteString;
    }
    return .{ .count = count, .command = command };
}
