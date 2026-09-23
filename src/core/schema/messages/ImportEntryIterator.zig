const Decoder = @import("../Decoder.zig");
const ImportEntry = @import("ImportEntry.zig");
const history = @import("history.zig");
const ImportEntryIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *ImportEntryIterator) !?ImportEntry {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    const started_at_ms = try self.decoder.readInt(i64);
    const command = try self.decoder.readSized16();
    if (command.len == 0 or command.len > history.max_import_command_bytes) {
        return error.InvalidByteString;
    }
    return .{ .started_at_ms = started_at_ms, .command = command };
}
