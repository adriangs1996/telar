const max_image_bytes_per_pane_module = @import("telar-core").max_image_bytes_per_pane;
const max_image_bytes_global_module = @import("telar-core").max_image_bytes_global;
const max_images_per_pane_module = @import("telar-core").max_images_per_pane;
const max_placements_per_pane_module = @import("telar-core").max_placements_per_pane;
const max_encoded_chunk_bytes_module = @import("telar-core").max_encoded_chunk_bytes;
const max_chunks_per_image_module = @import("telar-core").max_chunks_per_image;
/// Runtime-owned KGP budgets. Values may be lowered by future user
/// configuration but never raised past the protocol hard limits shared with
/// clients, so every snapshot remains decodable by every compatible client.
const GraphicsLimits = @This();

pane_bytes: usize = max_image_bytes_per_pane_module,
global_bytes: usize = max_image_bytes_global_module,
images_per_pane: usize = max_images_per_pane_module,
placements_per_pane: usize = max_placements_per_pane_module,
payload_bytes: usize = max_encoded_chunk_bytes_module,
chunks_per_image: usize = max_chunks_per_image_module,

pub fn validate(limits: GraphicsLimits) !void {
    if (limits.pane_bytes < 2 or limits.pane_bytes > max_image_bytes_per_pane_module or
        limits.global_bytes < limits.pane_bytes or limits.global_bytes > max_image_bytes_global_module or
        limits.images_per_pane < 2 or limits.images_per_pane > max_images_per_pane_module or
        limits.placements_per_pane < 2 or limits.placements_per_pane > max_placements_per_pane_module or
        limits.payload_bytes == 0 or limits.payload_bytes > max_encoded_chunk_bytes_module or
        limits.chunks_per_image == 0 or limits.chunks_per_image > max_chunks_per_image_module)
    {
        return error.InvalidGraphicsLimits;
    }
}
