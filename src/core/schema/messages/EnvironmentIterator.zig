const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const EnvironmentEntry = @import("../EnvironmentEntry.zig");
const codec = @import("../codec.zig");
const EnvironmentIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *EnvironmentIterator) !?EnvironmentEntry {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    const entry: EnvironmentEntry = .{
        .name = try self.decoder.readSized16(),
        .value = try self.decoder.readSized32(),
    };
    try codec.validateEnvironmentEntry(entry);
    return entry;
}
