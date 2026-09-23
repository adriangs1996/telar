const Decoder = @import("../Decoder.zig");
const TabDescriptorView = @import("TabDescriptorView.zig");
const id = @import("../id.zig");
const TabDescriptorIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *TabDescriptorIterator) !?TabDescriptorView {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    var descriptor: TabDescriptorView = .{
        .tab_id = try id.tab(try self.decoder.readInt(u64)),
        .position = try self.decoder.readInt(u16),
        .pane_count = try self.decoder.readInt(u16),
        .label = try self.decoder.readSized16(),
        .foreground_count = try self.decoder.readInt(u16),
        .encoded_foregrounds = undefined,
    };
    const start = self.decoder.index;
    for (0..descriptor.foreground_count) |_| {
        _ = try self.decoder.readInt(u64);
        _ = try self.decoder.readSized16();
    }

    descriptor.encoded_foregrounds = self.decoder.consumed(start);
    return descriptor;
}
