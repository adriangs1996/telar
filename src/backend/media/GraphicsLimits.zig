const core = @import("telar-core");
/// Runtime-owned KGP budgets. Values may be lowered by future user
/// configuration but never raised past the protocol hard limits shared with
/// clients, so every snapshot remains decodable by every compatible client.
const GraphicsLimits = @This();

pane_bytes: usize = core.max_image_bytes_per_pane,
global_bytes: usize = core.max_image_bytes_global,
images_per_pane: usize = core.max_images_per_pane,
placements_per_pane: usize = core.max_placements_per_pane,
payload_bytes: usize = core.max_encoded_chunk_bytes,
chunks_per_image: usize = core.max_chunks_per_image,

pub fn validate(self: GraphicsLimits) !void {
    if (self.pane_bytes < 2 or self.pane_bytes > core.max_image_bytes_per_pane or
        self.global_bytes < self.pane_bytes or self.global_bytes > core.max_image_bytes_global or
        self.images_per_pane < 2 or self.images_per_pane > core.max_images_per_pane or
        self.placements_per_pane < 2 or self.placements_per_pane > core.max_placements_per_pane or
        self.payload_bytes == 0 or self.payload_bytes > core.max_encoded_chunk_bytes or
        self.chunks_per_image == 0 or self.chunks_per_image > core.max_chunks_per_image)
    {
        return error.InvalidGraphicsLimits;
    }
}
