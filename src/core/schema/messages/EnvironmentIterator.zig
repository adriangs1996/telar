const EnvironmentIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("launch.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *EnvironmentIterator) !?source_namespace.EnvironmentEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    const entry: source_namespace.EnvironmentEntry = .{
        .name = try iterator.decoder.readSized16(),
        .value = try iterator.decoder.readSized32(),
    };
    try source_namespace.validateEnvironmentEntry(entry);
    return entry;
}
