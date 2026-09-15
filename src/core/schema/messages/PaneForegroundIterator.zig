const Decoder = @import("../Decoder.zig");
const PaneForeground = @import("PaneForeground.zig");
const id = @import("../id.zig");
const PaneForegroundIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(iterator: *PaneForegroundIterator) !?PaneForeground {
    if (iterator.remaining == 0) {
        return null;
    }

    iterator.remaining -= 1;
    return .{ .pane_id = try id.pane(try iterator.decoder.readInt(u64)), .name = try iterator.decoder.readSized16() };
}
