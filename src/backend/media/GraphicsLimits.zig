/// Runtime-owned KGP budgets. Values may be lowered by future user
/// configuration but never raised past the protocol hard limits shared with
/// clients, so every snapshot remains decodable by every compatible client.
const GraphicsLimits = @This();
const core = @import("telar-core");
pane_bytes: usize = core.graphics.max_image_bytes_per_pane,
global_bytes: usize = core.graphics.max_image_bytes_global,
images_per_pane: usize = core.graphics.max_images_per_pane,
placements_per_pane: usize = core.graphics.max_placements_per_pane,
payload_bytes: usize = core.graphics.max_encoded_chunk_bytes,
chunks_per_image: usize = core.graphics.max_chunks_per_image,

pub fn validate(limits: GraphicsLimits) !void {
    if (limits.pane_bytes < 2 or limits.pane_bytes > core.graphics.max_image_bytes_per_pane or
        limits.global_bytes < limits.pane_bytes or limits.global_bytes > core.graphics.max_image_bytes_global or
        limits.images_per_pane < 2 or limits.images_per_pane > core.graphics.max_images_per_pane or
        limits.placements_per_pane < 2 or limits.placements_per_pane > core.graphics.max_placements_per_pane or
        limits.payload_bytes == 0 or limits.payload_bytes > core.graphics.max_encoded_chunk_bytes or
        limits.chunks_per_image == 0 or limits.chunks_per_image > core.graphics.max_chunks_per_image)
    {
        return error.InvalidGraphicsLimits;
    }
}
