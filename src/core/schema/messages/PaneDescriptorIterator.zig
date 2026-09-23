const tab = @import("tab.zig");
const Decoder = @import("../Decoder.zig");
const PaneDescriptor = @import("../PaneDescriptor.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const PaneDescriptorIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *PaneDescriptorIterator) !?PaneDescriptor {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    return .{
        .pane_id = try id.pane(try self.decoder.readInt(u64)),
        .lifecycle = try codec.decodePaneLifecycle(try self.decoder.readByte()),
        .kind = try tab.decodePaneKind(try self.decoder.readByte()),
        .pane_generation = try self.decoder.readInt(u64),
    };
}
