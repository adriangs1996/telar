const DecoderType = @import("../Decoder.zig");
const EnvironmentEntryType = @import("../EnvironmentEntry.zig");
const codec = @import("../codec.zig");
const EnvironmentIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *EnvironmentIterator) !?EnvironmentEntryType {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const entry: EnvironmentEntryType = .{
        .name = try iterator.decoder.readSized16(),
        .value = try iterator.decoder.readSized32(),
    };
    try codec.validateEnvironmentEntry(entry);
    return entry;
}
