const core = @import("telar-core");
const OwnedAgentPrompt = @This();

request_id: core.RequestId,
pane_id: core.PaneId,
pane_generation: u64,
len: u16 = 0,
image_lengths: [core.AgentImages.capacity]u16 = @splat(0),
image_count: u8 = 0,
options: core.AgentOptions = .{},

/// Borrows this slot's owned prompt only during encoding. Example: `try core.encodeAgentPrompt(buffer, owned.view(bytes));`
pub fn view(self: *const OwnedAgentPrompt, bytes: []const u8) core.AgentPrompt {
    var images: core.AgentImagePaths = .{ .count = self.image_count };
    var offset: usize = self.len;
    for (self.image_lengths[0..self.image_count], 0..) |length, index| {
        images.storage[index] = bytes[offset..][0..length];
        offset += length;
    }

    return .{
        .request_id = self.request_id,
        .pane_id = self.pane_id,
        .pane_generation = self.pane_generation,
        .text = bytes[0..self.len],
        .options = self.options,
        .images = images,
    };
}
