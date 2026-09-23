const Decoder = @import("../Decoder.zig");
const PaneForeground = @import("PaneForeground.zig");
const id = @import("../id.zig");
const PaneForegroundIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *PaneForegroundIterator) !?PaneForeground {
    if (self.remaining == 0) {
        return null;
    }

    self.remaining -= 1;
    return .{ .pane_id = try id.pane(try self.decoder.readInt(u64)), .name = try self.decoder.readSized16() };
}
