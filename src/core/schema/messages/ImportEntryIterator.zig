const DecoderType = @import("../Decoder.zig");
const ImportEntry = @import("ImportEntry.zig");
const history = @import("history.zig");
const ImportEntryIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *ImportEntryIterator) !?ImportEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const started_at_ms = try iterator.decoder.readInt(i64);
    const command = try iterator.decoder.readSized16();
    if (command.len == 0 or command.len > history.max_import_command_bytes) {
        return error.InvalidByteString;
    }
    return .{ .started_at_ms = started_at_ms, .command = command };
}
