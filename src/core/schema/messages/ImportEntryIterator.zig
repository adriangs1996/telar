const ImportEntryIterator = @This();
const wire = @import("../wire.zig");
const ImportEntry = @import("ImportEntry.zig");
const source_namespace = @import("history.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *ImportEntryIterator) !?ImportEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const started_at_ms = try iterator.decoder.readInt(i64);
    const command = try iterator.decoder.readSized16();
    if (command.len == 0 or command.len > source_namespace.max_import_command_bytes) {
        return error.InvalidByteString;
    }
    return .{ .started_at_ms = started_at_ms, .command = command };
}
