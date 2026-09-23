const Decoder = @import("../Decoder.zig");
const EnvironmentEntry = @import("../EnvironmentEntry.zig");
const codec = @import("../codec.zig");
const EnvironmentIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(iterator: *EnvironmentIterator) !?EnvironmentEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const entry: EnvironmentEntry = .{
        .name = try iterator.decoder.readSized16(),
        .value = try iterator.decoder.readSized32(),
    };
    try codec.validateEnvironmentEntry(entry);
    return entry;
}
