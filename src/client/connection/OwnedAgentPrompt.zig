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
pub fn view(owned: *const OwnedAgentPrompt, bytes: []const u8) core.AgentPrompt {
    var images: core.AgentImagePaths = .{ .count = owned.image_count };
    var offset: usize = owned.len;
    for (owned.image_lengths[0..owned.image_count], 0..) |length, index| {
        images.storage[index] = bytes[offset..][0..length];
        offset += length;
    }

    return .{
        .request_id = owned.request_id,
        .pane_id = owned.pane_id,
        .pane_generation = owned.pane_generation,
        .text = bytes[0..owned.len],
        .options = owned.options,
        .images = images,
    };
}
